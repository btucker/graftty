import Testing
import Foundation
@testable import GrafttyKit

/// Reproduces the "PR status only updates when I click between worktrees"
/// bug: a `gh pr list` / `gh pr checks` subprocess hangs (network flake,
/// rate-limit back-off, auth glitch), the store's `Set<String>`-based
/// `inFlight` guard keeps the path as "in flight" forever, and every
/// subsequent background poll plus every user-triggered `refresh()` for
/// that worktree short-circuits at the `inFlight.contains` gate — the
/// sidebar badge and breadcrumb PR button freeze at their last-cached
/// state until relaunch.
///
/// Mirrors `WorktreeStatsStoreInFlightRecoveryTests` (DIVERGE-4.4). The
/// contract under test: a hung fetch Task must not permanently lock out
/// future refreshes. A later refresh invocation must still be able to
/// land fresh PRInfo even if the prior Task never resumes. `PR-7.13`.
@Suite("PRStatusStore — in-flight stuck-refresh recovery (PR-7.13)")
struct PRStatusStoreInFlightRecoveryTests {

    @MainActor
    @Test func hungRefreshDoesNotLockOutSubsequentRefreshes() async throws {
        let callCount = SyncCounter()
        let freshPR = PRInfo(
            number: 42,
            title: "hello",
            url: URL(string: "https://github.com/foo/bar/pull/42")!,
            state: .open,
            checks: .none,
            fetchedAt: Date()
        )

        // First fetch hangs on a never-signaled AsyncStream. Models a
        // `gh pr list` subprocess stuck awaiting an HTTP response, or a
        // gh retry loop waiting for a rate-limit reset.
        let hang = AsyncStream<Void>.makeStream()
        let hangIterator = Box(hang.stream.makeAsyncIterator())

        let fetcher = HangingFetcher(
            callCount: callCount,
            hangIterator: hangIterator,
            fresh: freshPR
        )
        let origin = HostingOrigin(
            provider: .github, host: "github.com", owner: "foo", repo: "bar"
        )
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")
        // Give the hung Task a moment to register as in-flight.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isInFlightForTesting("/wt"))

        // Fast-forward the in-flight timestamp past the refresh cadence
        // so the next refresh treats the prior Task as abandoned and
        // supersedes it. In production this threshold is reached
        // naturally on the next tick ~30s after the hang.
        store.seedInFlightSinceForTesting(
            Date().addingTimeInterval(-3600),
            forWorktree: "/wt"
        )

        // With the Set-based inFlight bug, this refresh is silently
        // dropped because `inFlight.contains("/wt")` is still true.
        // With the fix, the time-bounded inFlight treats the prior Task
        // as abandoned and supersedes it; the generation bump ensures
        // the hung Task's late write (if it ever returns) is dropped.
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feat")

        for _ in 0..<100 {
            if store.infos["/wt"] == freshPR { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(
            store.infos["/wt"] == freshPR,
            "a hung prior refresh Task must not prevent a later refresh from publishing fresh PRInfo"
        )

        hang.continuation.finish()
    }
}

/// Test double: first invocation suspends on a never-signaled stream;
/// subsequent invocations return the canned `fresh` PRInfo. The actor
/// serializes access to `hangIterator` across concurrent invocations.
private actor HangingFetcher: PRFetcher {
    private let callCount: SyncCounter
    private let hangIterator: Box<AsyncStream<Void>.Iterator>
    private let fresh: PRInfo

    init(
        callCount: SyncCounter,
        hangIterator: Box<AsyncStream<Void>.Iterator>,
        fresh: PRInfo
    ) {
        self.callCount = callCount
        self.hangIterator = hangIterator
        self.fresh = fresh
    }

    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        let n = callCount.incrementAndGet()
        if n == 1 {
            _ = await hangIterator.value.next()
            // Unreachable in the hung scenario; kept for type-correctness.
            return nil
        }
        return fresh
    }
}

/// Swift 6 doesn't let an AsyncStream.Iterator cross actor boundaries
/// directly — wrap in a Sendable box. Same pattern as
/// `WorktreeStatsStoreInFlightRecoveryTests`.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Thread-safe counter shared with the `@Sendable` fetcher closure.
/// Same pattern as `WorktreeStatsStoreInFlightRecoveryTests`.
private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
