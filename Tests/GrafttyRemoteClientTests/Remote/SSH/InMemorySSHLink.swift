#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyProtocol
import GrafttyTunnel
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

    /// `serverChild` configures the pipeline of every server-side session
    /// child channel.
    static func make(
        serverChild: @escaping @Sendable (Channel) throws -> Void
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
                        try serverChild(child)
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

/// Accepts every subsystem request, swallows the first `unanswered` request
/// frames — a host whose mutator never returns for them — and answers each
/// later one with `reply`.
final class ScriptedSubsystemHost: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var unanswered: Int
    private let reply: Data
    private let received: RequestCounter?

    init(unanswered: Int = .max, reply: Data = Data(), received: RequestCounter? = nil) {
        self.unanswered = unanswered
        self.reply = reply
        self.received = received
    }

    /// Installs framing and a scripted host on a server child channel.
    /// `received` counts the request frames the host reads.
    static func install(
        unanswered: Int = .max,
        reply: Data = Data(),
        received: RequestCounter? = nil
    ) -> @Sendable (Channel) throws -> Void {
        { child in
            let pipeline = child.pipeline.syncOperations
            try pipeline.addHandler(SSHChannelDataCodec())
            try pipeline.addHandler(LengthPrefixedFraming.makeFrameDecoder())
            try pipeline.addHandler(LengthPrefixedFraming.makeFramePrepender())
            try pipeline.addHandler(ScriptedSubsystemHost(
                unanswered: unanswered, reply: reply, received: received
            ))
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received?.increment()
        guard unanswered == 0 else {
            unanswered -= 1
            return
        }
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: reply)), promise: nil)
    }

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

/// A `ReplyDeadline` that fires only when the test says so.
final class ManualReplyDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: @Sendable () -> Void] = [:]

    var deadline: ReplyDeadline {
        ReplyDeadline { [self] callback in
            let id = UUID()
            lock.withLock { pending[id] = callback }
            return { [weak self] in self?.lock.withLock { _ = self?.pending.removeValue(forKey: id) } }
        }
    }

    /// Suspends until a deadline is armed.
    func waitUntilArmed() async {
        while lock.withLock({ pending.isEmpty }) { await Task.yield() }
    }

    /// Fires every armed deadline.
    func fire() {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        callbacks.forEach { $0() }
    }
}

/// Counts request frames a scripted host has read.
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }

    /// Suspends until at least `target` frames have arrived.
    func waitUntil(_ target: Int) async {
        while count < target { await Task.yield() }
    }
}
