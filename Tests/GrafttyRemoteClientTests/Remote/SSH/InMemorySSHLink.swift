#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import GrafttyRemoteClient

/// An authenticated client/server SSH pair joined by two
/// `NIOAsyncTestingChannel`s — the event-loop type the production WebRTC
/// transport uses, whose scheduled-task clock never advances on its own.
/// Deadlines that only `scheduleTask` on that loop never fire here, which
/// is the point.
final class InMemorySSHLink: @unchecked Sendable {
    let client: NIOAsyncTestingChannel
    let clientHandler: NIOSSHHandler
    let server: NIOAsyncTestingChannel
    private let pumps: [Task<Void, Never>]

    private init(
        client: NIOAsyncTestingChannel,
        clientHandler: NIOSSHHandler,
        server: NIOAsyncTestingChannel,
        pumps: [Task<Void, Never>]
    ) {
        self.client = client
        self.clientHandler = clientHandler
        self.server = server
        self.pumps = pumps
    }

    /// `serverChild` builds the handler installed on every server-side
    /// session child channel.
    static func make(
        serverChild: @escaping @Sendable () -> any ChannelHandler & Sendable
    ) async throws -> InMemorySSHLink {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(
                rawRepresentation: serverKey.publicKey.rawRepresentation
            )
        )

        let server = NIOAsyncTestingChannel()
        try await server.eventLoop.submit {
            let handler = NIOSSHHandler(
                role: .server(SSHServerConfiguration(
                    hostKeys: [NIOSSHPrivateKey(ed25519Key: serverKey)],
                    userAuthDelegate: AcceptAnyPublicKey()
                )),
                allocator: server.allocator,
                inboundChildChannelInitializer: { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(serverChild())
                    }
                }
            )
            try server.pipeline.syncOperations.addHandler(handler)
        }.get()

        let client = NIOAsyncTestingChannel()
        let clientHandler = try await client.eventLoop.submit {
            let handler = SSHClientSetup.makeHandler(
                clientKey: clientKey,
                expectedHostFingerprint: hostFingerprint,
                allocator: client.allocator
            )
            try client.pipeline.syncOperations.addHandler(handler)
            return UncheckedBox(value: handler)
        }.get().value

        // Both ends must be active before bytes flow: NIOSSH traps on
        // inbound data in its idle state.
        let address = try SocketAddress(unixDomainSocketPath: "in-memory-ssh")
        try await server.connect(to: address).get()
        try await client.connect(to: address).get()
        let pumps = [pump(from: client, to: server), pump(from: server, to: client)]
        return InMemorySSHLink(
            client: client,
            clientHandler: clientHandler,
            server: server,
            pumps: pumps
        )
    }

    func close() async {
        pumps.forEach { $0.cancel() }
        _ = try? await client.close()
        _ = try? await server.close()
    }

    private static func pump(
        from source: NIOAsyncTestingChannel,
        to destination: NIOAsyncTestingChannel
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    let bytes = try await source.waitForOutboundWrite(as: ByteBuffer.self)
                    try await destination.writeInbound(bytes)
                } catch {
                    return
                }
            }
        }
    }
}

/// Accepts every subsystem request and swallows every request frame: a
/// host whose mutator never returns.
final class StalledSubsystemHost: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.SubsystemRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        if request.wantReply {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        }
    }
}

private final class AcceptAnyPublicKey: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.success)
    }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}
