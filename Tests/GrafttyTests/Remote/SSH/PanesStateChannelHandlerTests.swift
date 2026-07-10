import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

/// `PanesStateChannelHandler.startSubscription` spawns a `Task` that runs the
/// injected `subscribe` callback on the Swift-concurrency global executor and
/// marshals each snapshot write back via `loop.execute`. `EmbeddedChannel`/
/// `EmbeddedEventLoop` are single-thread-only, so polling
/// `embeddedEventLoop.run()` from the test thread while that background `Task`
/// calls `loop.execute` is a data race (NIO logs "EmbeddedEventLoop is not
/// thread-safe" and the process intermittently crashes). These tests use
/// `NIOAsyncTestingChannel`, whose loop *is* thread-safe: `waitForOutboundWrite`
/// drives the loop until a deferred snapshot write lands, and `waitUntil` drives
/// it while polling subscription state — no busy-poll on a single-thread loop,
/// no race.
final class PanesStateChannelHandlerTests: XCTestCase {

    /// @spec REMOTE-6.2: Immediately after accepting a `panes-state@graftty.dev`
    /// channel, the host shall send a `{"type":"snapshot","worktrees":[…]}`
    /// frame containing the current `[WorktreePanes]` array.
    func testEmitsInitialSnapshotOnChannelActive() async throws {
        let initial = makeWorktrees(count: 1)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = try await Self.channel(with: handler)
        // Drive the async subscribe → onChange → loop.execute → writeAndFlush path.
        let buf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)

        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: Data(buf.readableBytesView))
        XCTAssertEqual(decoded, .snapshot(initial))
    }

    /// @spec REMOTE-6.3: While a `panes-state@graftty.dev` channel is open,
    /// on any change to the host's `AppState.repos[*].worktrees`,
    /// splittree, attention state, or PR status, the host shall send a
    /// fresh `{"type":"snapshot","worktrees":[…]}` frame.
    func testReemitsOnFurtherSubscribeFires() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = try await Self.channel(with: handler)
        // Wait for the initial snapshot, then discard it.
        _ = try await channel.waitForOutboundWrite(as: ByteBuffer.self)

        let next = makeWorktrees(count: 2)
        await subscription.fire(next)
        let buf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)

        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: Data(buf.readableBytesView))
        XCTAssertEqual(decoded, .snapshot(next))
    }

    /// @spec REMOTE-6.4: When the channel closes (channelInactive), the
    /// handler shall cancel the subscription so the snapshot pipeline
    /// stops firing.
    func testCancelsSubscriptionOnClose() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = try await Self.channel(with: handler)
        try await waitUntil(on: channel) { subscription.subscribed }

        _ = try await channel.finish()
        try await waitUntil(on: channel) { subscription.cancelled }

        XCTAssertTrue(subscription.cancelled)
    }

    /// The race: subscribe() suspends, the channel closes before
    /// storeCancellable runs, the suspended subscribe then resumes — its
    /// Cancellable must still be cancelled, not silently leaked.
    func testCancelsSubscriptionIfChannelClosesWhileSubscribeIsSuspended() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = SuspendingFakeSubscription(initialSnapshot: initial)
        let handler = PanesStateChannelHandler(subscribe: { [subscription] cb in
            await subscription.subscribe(cb)
        })

        let channel = try await Self.channel(with: handler)
        // Wait until subscribe() has suspended (continuation stored) so the
        // race scenario is properly set up: subscribe is mid-flight.
        try await waitUntil(on: channel) { subscription.suspended }
        // Close the channel while subscribe() is still suspended.
        _ = try await channel.finish()
        // Now release the suspended subscribe and let it return a Cancellable.
        subscription.release()
        try await waitUntil(on: channel) { subscription.cancelled }

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
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil, isBusy: false, attentionSource: nil)
            )
        }
    }

    /// A `NIOAsyncTestingChannel` with `handler` installed on its (thread-safe)
    /// loop and connected so `channelActive` fires the subscription — the safe
    /// substitute for `EmbeddedChannel` when the handler bounces through Swift
    /// concurrency.
    private static func channel(
        with handler: PanesStateChannelHandler
    ) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(handler).get()
        try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).get()
        return channel
    }

    /// Drives the (thread-safe) testing loop while polling `condition`, letting
    /// the handler's background `Task` make progress. Replaces the old
    /// single-thread `runLoopUntil` busy-poll for assertions that observe
    /// subscription state rather than an outbound frame.
    private func waitUntil(
        on channel: NIOAsyncTestingChannel,
        timeout: TimeInterval = 2.0,
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return XCTFail("waitUntil timed out")
            }
            await channel.testingEventLoop.run()
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
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
