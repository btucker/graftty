import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

struct TeamChannelOpeningTests {
    enum Abort: CaseIterable, Sendable { case cancellation, close, timeout }

    @Test("@spec TEAM-14.31: If opening a team channel stalls before SSH channel confirmation, then the application shall honor cancellation, closure, and a wall-clock deadline, and close any late channel without closing the shared connection.", arguments: Abort.allCases)
    func openingCanBeAborted(abort: Abort) async throws {
        let clientChannel = NIOAsyncTestingChannel()
        let serverChannel = NIOAsyncTestingChannel()
        let probe = TeamOpeningProbe()
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedPeerStore(directory: directory)
        try store.add(SSHUserAuthTestSupport.makePeer(key: clientKey, kind: .mac))
        let serverHandler = TeamOpeningHandlerBox(handler: SSHServerSetup.makeHandler(
            hostKey: serverKey,
            trustedPeerStore: store,
            allocator: serverChannel.allocator,
            inboundChildChannelInitializer: { child, _ in
                let ready = child.eventLoop.makePromise(of: Void.self)
                probe.hold(child: child, ready: ready)
                return ready.futureResult
            }
        ))
        let clientHandler = TeamOpeningHandlerBox(handler: SSHClientSetup.makeHandler(
            clientKey: clientKey,
            expectedHostFingerprint: RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: serverKey.publicKey.rawRepresentation)),
            allocator: clientChannel.allocator
        ))
        try await serverChannel.testingEventLoop.executeInContext {
            try serverChannel.pipeline.syncOperations.addHandler(serverHandler.handler)
        }
        try await clientChannel.testingEventLoop.executeInContext {
            try clientChannel.pipeline.syncOperations.addHandler(clientHandler.handler)
            try clientChannel.pipeline.syncOperations.addHandler(TeamOpeningAuthenticationRelay(probe: probe))
        }
        try await serverChannel.connect(to: .init(unixDomainSocketPath: "/tmp/team-opening-server")).get()
        try await clientChannel.connect(to: .init(unixDomainSocketPath: "/tmp/team-opening-client")).get()
        let pump = Task {
            while !Task.isCancelled {
                await clientChannel.testingEventLoop.run()
                await serverChannel.testingEventLoop.run()
                while let bytes = try await clientChannel.readOutbound(as: IOData.self) {
                    try await serverChannel.writeInbound(bytes)
                }
                while let bytes = try await serverChannel.readOutbound(as: IOData.self) {
                    try await clientChannel.writeInbound(bytes)
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { pump.cancel() }
        let client = TeamChannelClient(
            parentChannel: clientChannel,
            parentHandler: clientHandler.handler,
            handler: { $0 },
            openTimeout: abort == .timeout ? .seconds(10) : .seconds(60)
        )
        var opening: Task<Void, Never>?
        do {
            // Authentication involves several pump turns and must finish
            // before the test starts measuring the channel-open deadline.
            try await wait(for: .authentication) { probe.isAuthenticated }
            opening = Task {
                do { try await client.open(); probe.complete(.success(())) }
                catch { probe.complete(.failure(error)) }
            }
            try await wait(for: .childCreation) { probe.hasPendingChild }
            switch abort {
            case .cancellation: opening?.cancel()
            case .close: client.close()
            case .timeout: break
            }
            // Do not advance either virtual event loop's clock. The
            // production transport uses these loops, too.
            try await wait(for: .abortCompletion) { probe.result != nil }
            switch try #require(probe.result) {
            case .success: Issue.record("an aborted channel open succeeded")
            case .failure(let error):
                switch abort {
                case .cancellation: #expect(error is CancellationError)
                case .close:
                    guard case TeamChannelClient.ClientError.channelClosed = error else {
                        Issue.record("unexpected close error: \(error)")
                        break
                    }
                case .timeout:
                    guard case TeamChannelClient.ClientError.timedOut = error else {
                        Issue.record("unexpected timeout error: \(error)")
                        break
                    }
                }
            }
            #expect(clientChannel.isActive)
            probe.releaseChild()
            try await wait(for: .childCleanup) { probe.childClosed }
            #expect(clientChannel.isActive)
            #expect(serverChannel.isActive)
        } catch {
            probe.releaseChild()
            client.close()
            _ = try? await clientChannel.finish()
            _ = try? await serverChannel.finish()
            await opening?.value
            throw error
        }
        client.close()
        _ = try? await clientChannel.finish()
        _ = try? await serverChannel.finish()
        await opening?.value
    }

    private enum WaitPhase: String { case authentication, childCreation, abortCompletion, childCleanup }
    private struct WaitTimeout: Error, CustomStringConvertible {
        let phase: WaitPhase
        var description: String { "Team channel test timed out during \(phase.rawValue)" }
    }

    private func wait(for phase: WaitPhase, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        // A loaded test runner can resume this task after the event already
        // happened. Inspect the event before deciding the watchdog expired.
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitTimeout(phase: phase) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class TeamOpeningProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Channel?
    private var ready: EventLoopPromise<Void>?
    private var completion: Result<Void, Error>?
    private var didClose = false
    private var authenticated = false

    var isAuthenticated: Bool { lock.withLock { authenticated } }
    var hasPendingChild: Bool { lock.withLock { child != nil } }
    var childClosed: Bool { lock.withLock { didClose } }
    var result: Result<Void, Error>? { lock.withLock { completion } }

    func hold(child: Channel, ready: EventLoopPromise<Void>) {
        lock.withLock { self.child = child; self.ready = ready }
        child.closeFuture.whenComplete { [self] _ in lock.withLock { didClose = true } }
    }

    func releaseChild() {
        let ready = lock.withLock {
            defer { self.ready = nil }
            return self.ready
        }
        ready?.succeed(())
    }

    func complete(_ result: Result<Void, Error>) { lock.withLock { completion = result } }
    func didAuthenticate() { lock.withLock { authenticated = true } }
}

private final class TeamOpeningAuthenticationRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let probe: TeamOpeningProbe

    init(probe: TeamOpeningProbe) { self.probe = probe }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { probe.didAuthenticate() }
        context.fireUserInboundEventTriggered(event)
    }
}

private struct TeamOpeningHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler
}
