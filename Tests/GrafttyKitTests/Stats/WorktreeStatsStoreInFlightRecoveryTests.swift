import Testing
import Foundation
@testable import GrafttyKit

/// Reproduces the 2026-04-22 stuck-stats bug (`DIVERGE-4.x-stuck-recovery`):
/// a refresh's compute invocation hangs (e.g., a `git` subprocess blocked
/// waiting on a ref-transaction lock held by a concurrent `git push`).
/// With the original `inFlight` guard, every subsequent `refresh` call
/// returned early because `inFlight.contains(path)` stayed true forever —
/// so after the real origin ref settled, the store had no way to publish
/// the new (0, 0) divergence, and the sidebar kept showing whatever
/// pathological `WorktreeStats` the one-shot race had captured.
///
/// The contract under test: a hung refresh Task must not permanently
/// lock out future refreshes. A later refresh invocation must still be
/// able to land fresh stats even if the prior Task never resumes.
@Suite("WorktreeStatsStore — in-flight stuck-refresh recovery")
struct WorktreeStatsStoreInFlightRecoveryTests {

    @MainActor
    @Test func hungRefreshDoesNotLockOutSubsequentRefreshes() async throws {
        let callCount = SyncCounter()
        let freshStats = WorktreeStats(
            ahead: 0,
            behind: 0,
            insertions: 0,
            deletions: 0
        )

        // Use an AsyncStream we never signal — the first compute suspends
        // on `next()` forever. Models a git subprocess hung on a ref-lock
        // waiting for a concurrent push's transaction to complete.
        let hang = AsyncStream<Void>.makeStream()
        let hangIterator = Box(hang.stream.makeAsyncIterator())

        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _, _ in
            let n = callCount.incrementAndGet()
            if n == 1 {
                _ = await hangIterator.value.next()
                // Unreachable in the hung scenario; kept for type-correctness.
                return WorktreeStatsStore.ComputeResult(
                    defaultBranch: "main",
                    stats: nil
                )
            }
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: freshStats
            )
        }

        let store = WorktreeStatsStore(compute: compute, fetch: { _ in })

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")
        // Give the hung Task a moment to register as in-flight.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isInFlightForTesting("/wt"))

        // Fast-forward the in-flight timestamp past `statsRefreshCadence`
        // so the next refresh treats the prior Task as abandoned and
        // supersedes it. In production this threshold is reached
        // naturally on the next pollTick cadence (~30s after the hang).
        store.seedInFlightSinceForTesting(
            Date().addingTimeInterval(-3600),
            forWorktree: "/wt"
        )

        // With the bug, this refresh is silently dropped because
        // `inFlight.contains("/wt")` is still true. With the fix, it
        // supersedes the hung Task (generation bump drops the latter's
        // late apply) and lands `freshStats`.
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature")

        for _ in 0..<100 {
            if store.stats["/wt"] == freshStats { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(
            store.stats["/wt"] == freshStats,
            "a hung prior refresh Task must not prevent a later refresh from publishing fresh stats"
        )

        hang.continuation.finish()
    }
}

/// Swift 6 doesn't let an AsyncStream.Iterator cross actor boundaries
/// directly — wrap in a Sendable box. Mirrors the pattern in
/// `WorktreeStatsStoreClearTests`.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Thread-safe counter shared with the `@Sendable` compute closure.
/// Mirrors the pattern in `WorktreeStatsStoreComputeFailureTests`.
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
