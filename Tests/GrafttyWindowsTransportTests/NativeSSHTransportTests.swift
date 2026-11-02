import Foundation
import Crypto
import GrafttyTunnel
import NIOCore
import NIOPosix
import NIOSSH
import Testing

/// Runs unchanged on Mac, Linux, and Windows. These fixtures exercise the
/// dependencies and the real Graftty framing codecs, not the host's trust store.
@Suite(.serialized)
struct NativeSSHTransportTests {
    @Test("@spec REMOTE-32.1: When a headless host uses native TCP SSH transport, the application shall carry framed messages bidirectionally with pinned Ed25519 host keys and public-key client authentication.", .timeLimit(.minutes(1)))
    func framedSSHExchange() async throws {
        #expect(try await exchange() == Self.payload)
    }

    @Test("@spec REMOTE-32.3: When a headless machine initiates its authenticated connection to the parent Mac, the application shall carry parent-originated control channels on that connection without opening a listener on the headless machine.", .timeLimit(.minutes(1)))
    func parentOpensChannelOnOutboundHostConnection() async throws {
        #expect(try await exchange(reverseChannel: true) == Self.payload)
    }

    @Test("@spec REMOTE-32.2: If a native TCP SSH connection presents an unexpected host or client key, then the application shall reject the connection before delivering framed application data.", .timeLimit(.minutes(1)), arguments: ["host", "client"])
    func rejectsUnexpectedKeys(key: String) async throws {
        do {
            _ = try await exchange(pinHost: key != "host", authorizeClient: key != "client")
            Issue.record("Unexpected key was accepted")
        } catch FixtureFailure.deadline {
            Issue.record("Authentication did not fail before the deadline")
        } catch {
            // The parent channel must fail rather than deliver a response.
        }
    }

    private static var payload: String { String(repeating: "native-SSH-工具\n", count: 8192) }

    private func exchange(pinHost: Bool = true, authorizeClient: Bool = true, reverseChannel: Bool = false) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let result = Completion(loop.makePromise(of: String.self))
        let deadline = loop.scheduleTask(in: .seconds(10)) { result.complete(.failure(FixtureFailure.deadline)) }
        let serverKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let clientKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let trustedClient = authorizeClient ? clientKey.publicKey : NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let pinnedHost = pinHost ? serverKey.publicKey : NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let connections = Connections()
        var listener: Channel?
        var client: Channel?
        let outcome: Result<String, any Error>
        do {
            listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                connections.append(channel)
                let configuration = SSHServerConfiguration(hostKeys: [serverKey], userAuthDelegate: TrustedClient(key: trustedClient))
                let handler = NIOSSHHandler(role: .server(configuration), allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, type in
                        guard case .session = type else { return child.eventLoop.makeFailedFuture(FixtureFailure.channelType) }
                        let application: any ChannelHandler = reverseChannel ? RegisterAndOpen(parent: channel, result: result) : Echo()
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandlers(Self.framing() + [application])
                        }
                    })
                return channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) }
            }.bind(host: "127.0.0.1", port: 0).get()
            let port = try #require(listener?.localAddress?.port)
            client = try await ClientBootstrap(group: group).connectTimeout(.seconds(5)).channelInitializer { channel in
                let configuration = SSHClientConfiguration(userAuthDelegate: ClientKey(key: clientKey), serverAuthDelegate: PinnedHost(key: pinnedHost))
                let ssh = NIOSSHHandler(role: .client(configuration), allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, type in
                        guard reverseChannel, case .session = type else { return child.eventLoop.makeFailedFuture(FixtureFailure.channelType) }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandlers(Self.framing() + [Echo()])
                        }
                    })
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(ssh, OpenSession(result: result, registerOnly: reverseChannel))
                }
            }.connect(host: "127.0.0.1", port: port).get()
            outcome = .success(try await result.promise.futureResult.get())
        } catch { outcome = .failure(error) }
        deadline.cancel()
        if let client { try? await client.close().get() }
        if let listener { try? await listener.close().get() }
        for channel in connections.all { try? await channel.close().get() }
        try await group.shutdownGracefully()
        return try outcome.get()
    }

    fileprivate static func framing() -> [any ChannelHandler] {
        [SSHChannelDataCodec(), LengthPrefixedFraming.makeFrameDecoder(maximumBufferSize: 512 * 1024),
         LengthPrefixedFraming.makeFramePrepender()]
    }

    fileprivate static var request: String { payload }
}

private enum FixtureFailure: Error { case deadline, hostKey, clientKey, channelType, closed }

private final class Completion: @unchecked Sendable {
    let promise: EventLoopPromise<String>
    private let lock = NSLock()
    private var finished = false
    init(_ promise: EventLoopPromise<String>) { self.promise = promise }
    func complete(_ result: Result<String, any Error>) {
        lock.lock()
        let accepted = !finished
        finished = true
        lock.unlock()
        if accepted { promise.completeWith(result) }
    }
}

private final class Connections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []
    func append(_ channel: Channel) { lock.lock(); defer { lock.unlock() }; channels.append(channel) }
    var all: [Channel] { lock.lock(); defer { lock.unlock() }; return channels }
}

private struct TrustedClient: NIOSSHServerUserAuthenticationDelegate {
    let key: NIOSSHPublicKey
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey(let offered) = request.request, offered.publicKey == key { responsePromise.succeed(.success) }
        else { responsePromise.succeed(.failure) }
    }
}

private struct PinnedHost: NIOSSHClientServerAuthenticationDelegate {
    let key: NIOSSHPublicKey
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if hostKey == key { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(FixtureFailure.hostKey) }
    }
}

private final class ClientKey: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let key: NIOSSHPrivateKey
    private var offered = false // Used on one parent channel's event loop.
    init(key: NIOSSHPrivateKey) { self.key = key }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else { nextChallengePromise.fail(FixtureFailure.clientKey); return }
        offered = true
        nextChallengePromise.succeed(.init(username: "graftty", serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
    }
}

private final class Echo: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

private final class OpenSession: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let result: Completion
    let registerOnly: Bool
    init(result: Completion, registerOnly: Bool = false) { self.result = result; self.registerOnly = registerOnly }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is UserAuthSuccessEvent else { context.fireUserInboundEventTriggered(event); return }
        do {
            try openSession(parent: context.channel, result: result, registerOnly: registerOnly)
        } catch { result.complete(.failure(error)); context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { result.complete(.failure(error)); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { result.complete(.failure(FixtureFailure.closed)); context.fireChannelInactive() }
}

private func openSession(parent: Channel, result: Completion, registerOnly: Bool) throws {
    let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
    let opened = parent.eventLoop.makePromise(of: Channel.self)
    ssh.createChannel(opened) { child, type in
        guard case .session = type else { return child.eventLoop.makeFailedFuture(FixtureFailure.channelType) }
        return child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandlers(NativeSSHTransportTests.framing() + [Collect(result: result, registerOnly: registerOnly)])
        }
    }
    opened.futureResult.whenFailure { result.complete(.failure($0)) }
}

private final class RegisterAndOpen: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let parent: Channel
    let result: Completion
    private var opened = false
    init(parent: Channel, result: Completion) { self.parent = parent; self.result = result }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !opened, String(buffer: unwrapInboundIn(data)) == "headless-ready" else {
            result.complete(.failure(FixtureFailure.channelType)); context.close(promise: nil); return
        }
        opened = true
        do { try openSession(parent: parent, result: result, registerOnly: false) }
        catch { result.complete(.failure(error)); context.close(promise: nil) }
    }
}

private final class Collect: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let result: Completion
    let registerOnly: Bool
    init(result: Completion, registerOnly: Bool = false) { self.result = result; self.registerOnly = registerOnly }
    func channelActive(context: ChannelHandlerContext) {
        let message = registerOnly ? "headless-ready" : NativeSSHTransportTests.request
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: message)), promise: nil)
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        result.complete(.success(String(buffer: unwrapInboundIn(data))))
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { result.complete(.failure(error)); context.close(promise: nil) }
}
