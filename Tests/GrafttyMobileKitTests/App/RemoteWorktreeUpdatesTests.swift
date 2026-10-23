import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IOS-4.51: While a mobile view observes a paired host's worktrees, the application shall deliver the newest pushed panes-state frame without polling. When a subscription that delivered frames ends after staying open for at least a minimum lifetime, the application shall subscribe again immediately; when it ends sooner, the application shall wait a retry delay first without reporting the host unavailable. If subscribing fails or a subscription ends before delivering a frame, then the application shall report the host unavailable and subscribe again only after a retry delay, stopping once the view stops observing.", .timeLimit(.minutes(1)))
struct RemoteWorktreeUpdatesTests {
    @Test func replacesALongLivedChannelImmediately() async throws {
        let first = LatestValueBroadcast<PanesStateMessage>()
        let second = LatestValueBroadcast<PanesStateMessage>()
        let host = FakeSubscriptions([.success(first), .success(second)])
        let retry = ManualRetry()
        let clock = TestClock()
        var updates = observe(host, retry, clock).makeAsyncIterator()

        first.publish(.snapshot(rows("a")))
        try #require(await updates.next() == .frame(.snapshot(rows("a"))))
        first.publish(.snapshot(rows("b")))
        try #require(await updates.next() == .frame(.snapshot(rows("b"))))

        // A replaced or reopened channel is not an outage: the next store's
        // frame follows with no unavailable gap and no retry delay.
        clock.advance(by: .seconds(5))
        second.publish(.snapshot(rows("c")))
        first.finish()
        try #require(await updates.next() == .frame(.snapshot(rows("c"))))
        #expect(host.calls == 2)
        #expect(retry.waitCount == 0)
    }

    @Test func shortLivedChannelsWaitBetweenSubscriptionsWithoutBlankingTheHost() async throws {
        let channels = (0..<6).map { _ in LatestValueBroadcast<PanesStateMessage>() }
        for (index, channel) in channels.enumerated() { channel.publish(.snapshot(rows("\(index)"))) }
        let host = FakeSubscriptions(channels.map { .success($0) })
        let retry = ManualRetry()
        let clock = TestClock()
        // Unbounded, so an unavailable event cannot hide behind a later frame.
        var updates = observe(host, retry, clock).makeAsyncIterator()

        // A single frame, then a quick close: wait before reopening.
        try #require(await updates.next() == .frame(.snapshot(rows("0"))))
        channels[0].finish()
        try #require(await retry.waitUntilPending())
        #expect(host.calls == 1)
        retry.release()
        try #require(await updates.next() == .frame(.snapshot(rows("1"))))

        // Two frames do not make a quick close healthy, and a completed delay
        // earns no immediate reopen.
        clock.advance(by: .seconds(1))
        channels[1].publish(.snapshot(rows("1b")))
        try #require(await updates.next() == .frame(.snapshot(rows("1b"))))
        channels[1].finish()
        try #require(await retry.waitUntilPending())
        #expect(host.calls == 2)
        retry.release()
        try #require(await updates.next() == .frame(.snapshot(rows("2"))))

        // Staying open for the minimum lifetime earns an immediate reopen.
        clock.advance(by: .seconds(5))
        channels[2].finish()
        try #require(await updates.next() == .frame(.snapshot(rows("3"))))
        #expect(retry.waitCount == 2)

        // Each channel's lifetime is its own: the quick successor of a mature
        // channel waits again.
        channels[3].finish()
        try #require(await retry.waitUntilPending())
        #expect(host.calls == 4)

        // Time spent opening the channel is not time open: a subscribe that
        // takes longer than the lifetime, then a quick close, still waits.
        host.beforeReturning = { clock.advance(by: .seconds(6)) }
        retry.release()
        try #require(await updates.next() == .frame(.snapshot(rows("4"))))
        channels[4].finish()
        try #require(await retry.waitUntilPending())
        #expect(host.calls == 5)
        #expect(retry.waitCount == 4)
    }

    @Test func reportsASubscriptionThatEndsBeforeAnyFrameAndRetries() async throws {
        let closed = LatestValueBroadcast<PanesStateMessage>()
        closed.finish()
        let recovered = LatestValueBroadcast<PanesStateMessage>()
        recovered.publish(.snapshot(rows("a")))
        let host = FakeSubscriptions([.success(closed), .success(recovered)])
        let retry = ManualRetry()
        var updates = RemoteWorktreeUpdates.stream(subscribe: host.subscribe, retryDelay: retry.wait)
            .makeAsyncIterator()

        try #require(await updates.next() == .unavailable)
        // An immediately closed store must not resubscribe in a hot loop.
        try #require(await retry.waitUntilPending())
        #expect(host.calls == 1)
        retry.release()
        try #require(await updates.next() == .frame(.snapshot(rows("a"))))
        #expect(host.calls == 2)
    }

    @Test func reportsAFailedSubscriptionAndRetries() async throws {
        let recovered = LatestValueBroadcast<PanesStateMessage>()
        recovered.publish(.snapshot(rows("a")))
        let host = FakeSubscriptions([.failure(FakeError()), .success(recovered)])
        let retry = ManualRetry()
        var updates = RemoteWorktreeUpdates.stream(subscribe: host.subscribe, retryDelay: retry.wait)
            .makeAsyncIterator()

        try #require(await updates.next() == .unavailable)
        try #require(await retry.waitUntilPending())
        #expect(host.calls == 1)
        retry.release()
        try #require(await updates.next() == .frame(.snapshot(rows("a"))))
        #expect(host.calls == 2)
    }

    @Test func stopsRetryingWhenTheObserverStops() async throws {
        let host = FakeSubscriptions([.failure(FakeError())])
        let retry = ManualRetry()
        let observer = Task { @MainActor in
            for await _ in RemoteWorktreeUpdates.stream(subscribe: host.subscribe, retryDelay: retry.wait) {}
            // An observation that ends on its own fails the waits below
            // instead of hanging them.
            retry.abandon()
        }
        try #require(await retry.waitUntilPending())
        observer.cancel()
        await observer.value
        // The pending delay is abandoned rather than leading to a subscribe.
        try #require(await retry.waitUntilCancelled())
        #expect(host.calls == 1)
    }
}

private struct FakeError: Error {}

@MainActor
private func observe(_ host: FakeSubscriptions, _ retry: ManualRetry, _ clock: TestClock)
    -> AsyncStream<RemoteWorktreeUpdate> {
    RemoteWorktreeUpdates.stream(
        subscribe: host.subscribe, retryDelay: retry.wait,
        minimumChannelLifetime: .seconds(5), now: clock.now, bufferingPolicy: .unbounded
    )
}

@MainActor
private final class TestClock {
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    func now() -> ContinuousClock.Instant { start.advanced(by: elapsed) }
    func advance(by duration: Duration) { elapsed += duration }
}

private func rows(_ name: String) -> [WorktreePanes] {
    [WorktreePanes(path: "/repo/\(name)", displayName: name, repoDisplayName: "repo", displayBranch: name,
                   state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)]
}

@MainActor
private final class FakeSubscriptions {
    private var results: [Result<LatestValueBroadcast<PanesStateMessage>, any Error>]
    private(set) var calls = 0

    init(_ results: [Result<LatestValueBroadcast<PanesStateMessage>, any Error>]) {
        self.results = results
    }

    /// Runs inside each subscribe before it returns, so a test can spend
    /// time opening the channel.
    var beforeReturning: () -> Void = {}

    func subscribe() async throws -> AsyncStream<PanesStateMessage> {
        calls += 1
        beforeReturning()
        guard !results.isEmpty else { throw FakeError() }
        return try results.removeFirst().get().updates()
    }
}

/// A retry delay the test releases by hand. Waiting reports itself through
/// `pending`, and a cancelled wait reports through `cancelled`.
@MainActor
private final class ManualRetry {
    private var waiter: CheckedContinuation<Void, any Error>?
    private(set) var waitCount = 0
    private let pending = AsyncStream<Void>.makeStream()
    private let cancelled = AsyncStream<Void>.makeStream()

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitCount += 1
                waiter = continuation
                pending.continuation.yield()
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter() }
        }
    }

    func waitUntilPending() async -> Bool { await Self.next(pending.stream) }
    func waitUntilCancelled() async -> Bool { await Self.next(cancelled.stream) }

    private static func next(_ signals: AsyncStream<Void>) async -> Bool {
        var iterator = signals.makeAsyncIterator()
        return await iterator.next() != nil
    }

    /// Only `pending` ends: the cancellation signal may still be in flight.
    func abandon() { pending.continuation.finish() }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    private func cancelWaiter() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
        cancelled.continuation.yield()
    }
}
