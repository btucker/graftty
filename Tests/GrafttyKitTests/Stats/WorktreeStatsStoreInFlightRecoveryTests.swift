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
@Suite("""
WorktreeStatsStore — in-flight stuck-refresh recovery

@spec DIVERGE-4.4: While a divergence computation is in flight for a particular worktree, duplicate refresh requests for that worktree shall be coalesced into at most one trailing refresh carrying the latest repository and branch values. Each generation-valid computation shall publish its completed snapshot before the trailing refresh begins, so computations slower than the polling interval still make visible progress instead of perpetually suppressing one another. After 30 seconds (the in-flight abandonment threshold), a subsequent refresh shall supersede the prior Task immediately: the generation counter is bumped so the stuck Task's late `apply` is discarded, and the superseding request replaces any queued trailing request. `clear(worktreePath:)` shall discard both active and queued refresh state. Without trailing coalescing, an authoritative HEAD or post-fetch refresh that arrives behind an older computation is dropped and stale divergence can be published until the polling fallback.
""")
struct WorktreeStatsStoreInFlightRecoveryTests {

    @MainActor
    @Test func inFlightRefreshRunsOneTrailingComputeWithLatestBranch() async throws {
        let firstResume = AsyncStream<Void>.makeStream()
        let firstIterator = Box(firstResume.stream.makeAsyncIterator())
        let secondResume = AsyncStream<Void>.makeStream()
        let secondIterator = Box(secondResume.stream.makeAsyncIterator())
        let calls = BranchCallRecorder()

        let compute: WorktreeStatsStore.ComputeFunction = { _, _, branch, _ in
            let invocation = calls.record(branch)
            if invocation == 1 {
                _ = await firstIterator.value.next()
            } else if invocation == 2 {
                _ = await secondIterator.value.next()
            }
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(
                    ahead: invocation,
                    behind: 0,
                    insertions: 0,
                    deletions: 0
                )
            )
        }
        let store = WorktreeStatsStore(compute: compute, fetch: { _ in })

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "old")
        try await waitUntil { calls.branches == ["old"] }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "intermediate")
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "latest")
        #expect(calls.branches == ["old"])

        firstResume.continuation.yield(())
        firstResume.continuation.finish()

        try await waitUntil { calls.branches == ["old", "latest"] }
        // The trailing compute is deliberately still blocked. The first
        // valid snapshot must publish now; otherwise a compute that always
        // exceeds the poll interval can suppress every result forever.
        try await waitUntil { store.stats["/wt"]?.ahead == 1 }

        secondResume.continuation.yield(())
        secondResume.continuation.finish()
        try await waitUntil { store.stats["/wt"]?.ahead == 2 }
    }

    @MainActor
    @Test func clearDiscardsQueuedTrailingRefresh() async throws {
        let firstResume = AsyncStream<Void>.makeStream()
        let firstIterator = Box(firstResume.stream.makeAsyncIterator())
        let calls = BranchCallRecorder()
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, branch, _ in
            let invocation = calls.record(branch)
            if invocation == 1 {
                _ = await firstIterator.value.next()
            }
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: invocation, behind: 0, insertions: 0, deletions: 0)
            )
        }
        let store = WorktreeStatsStore(compute: compute, fetch: { _ in })

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "old")
        try await waitUntil { calls.branches == ["old"] }
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "queued")
        store.clear(worktreePath: "/wt")

        firstResume.continuation.yield(())
        firstResume.continuation.finish()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(calls.branches == ["old"])
        #expect(store.stats["/wt"] == nil)
    }

    @MainActor
    @Test func abandonmentSupersessionReplacesQueuedTrailingRefresh() async throws {
        let firstResume = AsyncStream<Void>.makeStream()
        let firstIterator = Box(firstResume.stream.makeAsyncIterator())
        let calls = BranchCallRecorder()
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, branch, _ in
            let invocation = calls.record(branch)
            if invocation == 1 {
                _ = await firstIterator.value.next()
            }
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: invocation, behind: 0, insertions: 0, deletions: 0)
            )
        }
        let store = WorktreeStatsStore(compute: compute, fetch: { _ in })

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "old")
        try await waitUntil { calls.branches == ["old"] }
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "queued")
        store.seedInFlightSinceForTesting(
            Date().addingTimeInterval(-3600),
            forWorktree: "/wt"
        )
        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "latest")

        try await waitUntil { calls.branches == ["old", "latest"] }
        firstResume.continuation.yield(())
        firstResume.continuation.finish()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(calls.branches == ["old", "latest"])
        #expect(store.stats["/wt"]?.ahead == 2)
    }

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

        // Fast-forward the in-flight timestamp past `inFlightAbandonmentThreshold`
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

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), "waitUntil timed out")
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

private final class BranchCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var branches: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ branch: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        values.append(branch)
        return values.count
    }
}
