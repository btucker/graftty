import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

final class PanesStateChannelHandlerTests: XCTestCase {

    /// @spec REMOTE-6.2: Immediately after accepting a `panes-state@graftty.dev`
    /// channel, the host shall send a `{"type":"snapshot","worktrees":[…]}`
    /// frame containing the current `[WorktreePanes]` array.
    func testEmitsInitialSnapshotOnChannelActive() throws {
        let initial = makeWorktrees(count: 1)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()
        // Drain the async subscribe → onChange → loop.execute → writeAndFlush path.
        var outboundBuf: ByteBuffer?
        runLoopUntil(channel: channel) {
            outboundBuf = try? channel.readOutbound(as: ByteBuffer.self)
            return outboundBuf != nil
        }

        guard let buf = outboundBuf else {
            return XCTFail("expected one outbound frame after channelActive")
        }
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: Data(buf.readableBytesView))
        XCTAssertEqual(decoded, .snapshot(initial))
    }

    /// @spec REMOTE-6.3: While a `panes-state@graftty.dev` channel is open,
    /// on any change to the host's `AppState.repos[*].worktrees`,
    /// splittree, attention state, or PR status, the host shall send a
    /// fresh `{"type":"snapshot","worktrees":[…]}` frame.
    func testReemitsOnFurtherSubscribeFires() throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()
        // Wait for initial snapshot, then discard it.
        runLoopUntil(channel: channel) {
            (try? channel.readOutbound(as: ByteBuffer.self)) != nil
        }

        let next = makeWorktrees(count: 2)
        Task { await subscription.fire(next) }
        var secondBuf: ByteBuffer?
        runLoopUntil(channel: channel) {
            secondBuf = try? channel.readOutbound(as: ByteBuffer.self)
            return secondBuf != nil
        }

        guard let buf = secondBuf else {
            return XCTFail("expected second frame on fire()")
        }
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: Data(buf.readableBytesView))
        XCTAssertEqual(decoded, .snapshot(next))
    }

    /// @spec REMOTE-6.4: When the channel closes (channelInactive), the
    /// handler shall cancel the subscription so the snapshot pipeline
    /// stops firing.
    func testCancelsSubscriptionOnClose() throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()
        runLoopUntil(channel: channel) { subscription.subscribed }

        _ = try channel.finish()
        runLoopUntil(channel: channel) { subscription.cancelled }

        XCTAssertTrue(subscription.cancelled)
    }

    /// The race: subscribe() suspends, the channel closes before
    /// storeCancellable runs, the suspended subscribe then resumes — its
    /// Cancellable must still be cancelled, not silently leaked.
    func testCancelsSubscriptionIfChannelClosesWhileSubscribeIsSuspended() throws {
        let initial = makeWorktrees(count: 0)
        let subscription = SuspendingFakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()
        // Wait until subscribe() has suspended (continuation stored) so the
        // race scenario is properly set up: subscribe is mid-flight.
        runLoopUntil(channel: channel) { subscription.suspended }
        // Close the channel while subscribe() is still suspended.
        _ = try channel.finish()
        channel.embeddedEventLoop.run()
        // Now release the suspended subscribe and let it return a Cancellable.
        subscription.release()
        runLoopUntil(channel: channel) { subscription.cancelled }

        XCTAssertTrue(subscription.cancelled)
    }

    // MARK: - helpers

    private func makeWorktrees(count: Int) -> [WorktreePanes] {
        (0..<count).map { idx in
            WorktreePanes(
                path: "/repo/wt-\(idx)",
                displayName: "wt-\(idx)",
                repoDisplayName: "graftty",
                displayBranch: "branch-\(idx)",
                state: .running,
                isMainCheckout: false,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil, isBusy: false)
            )
        }
    }

    /// EmbeddedChannel polling helper. Tasks spawned by the handler run
    /// on the global executor and schedule writes back via
    /// `loop.execute`. Spinning `RunLoop.main` lets those Tasks complete,
    /// then `embeddedEventLoop.run()` drains the pending writes.
    private func runLoopUntil(channel: EmbeddedChannel, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2.0)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            channel.embeddedEventLoop.run()
        }
    }
}

// MARK: - FakeSubscription

private final class FakeSubscription: @unchecked Sendable {
    private let lock = NIOLock()
    private var _subscribed = false
    private var _cancelled = false
    private var _onChange: (@Sendable ([WorktreePanes]) async -> Void)?
    private let initialSnapshot: [WorktreePanes]

    var subscribed: Bool { lock.withLock { _subscribed } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    init(initialSnapshot: [WorktreePanes]) {
        self.initialSnapshot = initialSnapshot
    }

    func subscribe(
        _ onChange: @escaping @Sendable ([WorktreePanes]) async -> Void
    ) async -> PanesStateChannelHandler.Cancellable {
        lock.withLock {
            _subscribed = true
            _onChange = onChange
        }
        await onChange(initialSnapshot)
        return PanesStateChannelHandler.Cancellable { [weak self] in
            self?.lock.withLock { self?._cancelled = true }
        }
    }

    func fire(_ snapshot: [WorktreePanes]) async {
        let cb = lock.withLock { _onChange }
        await cb?(snapshot)
    }
}

// MARK: - SuspendingFakeSubscription

/// A subscription helper that suspends inside `subscribe` until `release()`
/// is called. Used to exercise the channelInactive-races-storeCancellable
/// scenario: the channel closes while subscribe() is suspended; when
/// release() is called the returned Cancellable must be cancelled
/// immediately rather than stored on the now-inactive handler.
private final class SuspendingFakeSubscription: @unchecked Sendable {
    private let lock = NIOLock()
    private var _cancelled = false
    private var _suspended = false
    private var _continuation: CheckedContinuation<Void, Never>?
    private let initialSnapshot: [WorktreePanes]

    var cancelled: Bool { lock.withLock { _cancelled } }
    /// True once subscribe() has reached the suspension point.
    var suspended: Bool { lock.withLock { _suspended } }

    init(initialSnapshot: [WorktreePanes]) {
        self.initialSnapshot = initialSnapshot
    }

    func subscribe(
        _ onChange: @escaping @Sendable ([WorktreePanes]) async -> Void
    ) async -> PanesStateChannelHandler.Cancellable {
        // Fire the initial snapshot so the handler can write it, then suspend
        // until release() is called — simulating a slow subscribe path.
        await onChange(initialSnapshot)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock {
                _continuation = cont
                _suspended = true
            }
        }
        return PanesStateChannelHandler.Cancellable { [weak self] in
            self?.lock.withLock { self?._cancelled = true }
        }
    }

    /// Resumes the suspended subscribe() call so it can return its Cancellable.
    func release() {
        let cont = lock.withLock { _continuation }
        cont?.resume()
    }
}
