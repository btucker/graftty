import CryptoKit
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import GrafttyRemoteClient

@Suite("SSH child channel open deadlines")
struct SSHChildChannelOpenerTests {
    @Test("@spec IOS-12.6: If a browser tunnel cannot connect before its deadline, then the application shall fail that browser connection without disconnecting terminal panes sharing the host transport.")
    func browserTimeoutPreservesParent() async throws {
        let fixture = try await StalledSSHParent.make()
        let watchdog = fixture.closeAfterDelay()
        defer { watchdog.cancel() }
        await #expect(throws: SSHChildChannelOpenError.timedOut) {
            _ = try await openChildChannel(
                parentChannel: fixture.channel,
                parentHandler: fixture.handler,
                timeout: .milliseconds(25),
                closeParentOnTimeout: false
            ) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
        }
        #expect(fixture.channel.isActive)
        try await fixture.channel.close().get()
    }

    @Test("an already cancelled open leaves the parent available")
    func cancellationBeforeOpenPreservesParent() async throws {
        let fixture = try await StalledSSHParent.make()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await openChildChannel(
                parentChannel: fixture.channel,
                parentHandler: fixture.handler
            ) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(fixture.channel.isActive)
        try await fixture.channel.close().get()
    }

    @Test("@spec REMOTE-11.6: If a terminal or control SSH child channel cannot open before its deadline, then the client shall fail the open and close the stalled transport so a subsequent connection can retry.")
    func stalledOpenTimesOutWithoutAdvancingEventLoopClock() async throws {
        let fixture = try await StalledSSHParent.make()
        let watchdog = fixture.closeAfterDelay()
        defer { watchdog.cancel() }

        await #expect(throws: SSHChildChannelOpenError.timedOut) {
            _ = try await openChildChannel(
                parentChannel: fixture.channel,
                parentHandler: fixture.handler,
                timeout: .milliseconds(25)
            ) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
        }
        try await fixture.channel.closeFuture.get()
        #expect(!fixture.channel.isActive)
    }

    @Test("@spec REMOTE-11.7: When a pending SSH child channel open is cancelled, the client shall resume the caller with cancellation while preserving the shared parent transport and sibling channels.")
    func cancellationUnblocksPendingOpenAndPreservesParent() async throws {
        let fixture = try await StalledSSHParent.make()
        let watchdog = fixture.closeAfterDelay()
        defer { watchdog.cancel() }
        let task = Task {
            try await openChildChannel(
                parentChannel: fixture.channel,
                parentHandler: fixture.handler
            ) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
        }
        // Let the open park waiting for the peer, which never answers in this
        // fixture. Already-cancelled callers have a separate test above.
        try await Task.sleep(for: .milliseconds(25))
        let cancelledAt = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
        // Drain any close enqueued by cancellation before asserting that the
        // parent survived. The waiter can resume before cleanup reaches NIO.
        try await fixture.channel.eventLoop.submit {}.get()
        #expect(fixture.channel.isActive)
        fixture.channel.close(promise: nil)
        try await fixture.channel.closeFuture.get()
    }
}

/// Uses the production transport's event-loop type, with no peer to answer SSH.
private final class StalledSSHParent: @unchecked Sendable {
    let channel: NIOAsyncTestingChannel
    let handler: NIOSSHHandler

    private init(channel: NIOAsyncTestingChannel, handler: NIOSSHHandler) {
        self.channel = channel
        self.handler = handler
    }

    static func make() async throws -> StalledSSHParent {
        let channel = NIOAsyncTestingChannel()
        let fixture = try await channel.eventLoop.submit {
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = try RemoteIdentityPublicKey(
                rawRepresentation: key.publicKey.rawRepresentation
            )
            let handler = SSHClientSetup.makeHandler(
                clientKey: key,
                expectedHostFingerprint: .init(of: publicKey),
                allocator: channel.allocator
            )
            try channel.pipeline.syncOperations.addHandler(handler)
            return StalledSSHParent(channel: channel, handler: handler)
        }.get()
        try await channel.connect(to: .init(unixDomainSocketPath: "stalled-ssh-test")).get()
        return fixture
    }

    func closeAfterDelay() -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            Issue.record("SSH child open did not complete before watchdog cleanup")
            channel.close(promise: nil)
        }
    }
}
