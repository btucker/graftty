import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IOS-4.51: While a mobile view observes a paired host's worktrees, the application shall deliver each pushed panes-state frame without polling, shall report the host unavailable when its subscription fails or ends, and shall subscribe again only after a retry delay, stopping once the view stops observing.", .timeLimit(.minutes(1)))
struct RemoteWorktreeUpdatesTests {
    @Test func forwardsFramesAndResubscribesAfterTheChannelEnds() async throws {
        let first = LatestValueBroadcast<PanesStateMessage>()
        let second = LatestValueBroadcast<PanesStateMessage>()
        let host = FakeSubscriptions([.success(first), .success(second)])
        let retry = ManualRetry()
        var updates = RemoteWorktreeUpdates.stream(subscribe: host.subscribe, retryDelay: retry.wait)
            .makeAsyncIterator()

        first.publish(.snapshot(rows("a")))
        try #require(await updates.next() == .frame(.snapshot(rows("a"))))
        first.publish(.snapshot(rows("b")))
        try #require(await updates.next() == .frame(.snapshot(rows("b"))))

        first.finish()
        try #require(await updates.next() == .unavailable)
        // No new subscription until the retry delay elapses.
        try #require(await retry.waitUntilPending())
        #expect(host.calls == 1)

        second.publish(.snapshot(rows("c")))
        retry.release()
        try #require(await updates.next() == .frame(.snapshot(rows("c"))))
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

    func subscribe() async throws -> AsyncStream<PanesStateMessage> {
        calls += 1
        guard !results.isEmpty else { throw FakeError() }
        return try results.removeFirst().get().updates()
    }
}

/// A retry delay the test releases by hand. Waiting reports itself through
/// `pending`, and a cancelled wait reports through `cancelled`.
@MainActor
private final class ManualRetry {
    private var waiter: CheckedContinuation<Void, any Error>?
    private let pending = AsyncStream<Void>.makeStream()
    private let cancelled = AsyncStream<Void>.makeStream()

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
