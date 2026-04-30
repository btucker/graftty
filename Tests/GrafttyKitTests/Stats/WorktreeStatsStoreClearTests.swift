import Testing
import Foundation
@testable import GrafttyKit

/// DIVERGE-4.5: `clear(worktreePath:)` must release the `inFlight` gate
/// and bump a per-path generation counter so an in-flight refresh whose
/// `apply` fires after the clear discards its result instead of
/// repopulating `stats`. Mirrors the matching PRStatusStore tests from
/// the test suite of the same name.
@Suite("""
WorktreeStatsStore.clear

@spec DIVERGE-4.5: When `WorktreeStatsStore.clear(worktreePath:)` is called — whether from a stale transition (GIT-3.13), a Dismiss (GIT-3.6), or a Delete (GIT-4.10) — a fetch that was already in flight at that moment shall not repopulate `stats` after the clear. Each `clear` bumps a per-path generation counter; `apply` captures the generation at refresh time and drops the write if the counter changed during the await. Without this, a `git worktree remove` that fires shortly after the 5s-polling refresh leaves the divergence indicator flashing back onto a cleared row for the duration of the git subprocess (~50–200ms). Mirrors `PRStatusStore`'s pattern (PR status gained this protection earlier; stats store was lagging).
""")
struct WorktreeStatsStoreClearTests {

    @MainActor
    @Test func clearBumpsGenerationCounter() async {
        let store = WorktreeStatsStore()
        let before = store.generationForTesting("/wt")
        store.clear(worktreePath: "/wt")
        let after = store.generationForTesting("/wt")
        #expect(after == before + 1)
    }

    @MainActor
    @Test func repeatedClearsKeepBumpingGeneration() async {
        let store = WorktreeStatsStore()
        let start = store.generationForTesting("/wt")
        for _ in 0..<3 { store.clear(worktreePath: "/wt") }
        #expect(store.generationForTesting("/wt") == start + 3)
    }

    @MainActor
    @Test func refreshCapturesCurrentGeneration() async {
        let store = WorktreeStatsStore()
        // Force the generation to a known value via repeated clears.
        store.clear(worktreePath: "/wt")
        store.clear(worktreePath: "/wt")
        let gen = store.generationForTesting("/wt")
        #expect(gen == 2)

        // A subsequent clear will bump to 3; any Task that captured
        // gen=2 at its refresh time will see mismatch and drop its
        // apply.
        store.clear(worktreePath: "/wt")
        #expect(store.generationForTesting("/wt") == 3)
    }

    /// Cycle-125 integration test enabled by the compute-closure
    /// injection refactor. Simulates the DIVERGE-4.5 race deterministically:
    /// 1. refresh → compute closure suspends mid-flight (awaits a
    ///    signal the test owns)
    /// 2. clear() bumps generation while compute is suspended
    /// 3. Signal compute to resume; its output returns canned stats
    /// 4. apply() sees gen mismatch and drops the write — `stats["/wt"]`
    ///    stays nil instead of getting repopulated.
    ///
    /// Previously couldn't be written without configuring the global
    /// `GitRunner.executor`, which poisoned concurrent suites' stubs.
    /// With the injection the compute is per-instance and isolated.
    @MainActor
    @Test func clearBetweenRefreshAndApplyDropsStaleWrite() async throws {
        // Continuation that the test will resume after calling clear().
        let resumeStream = AsyncStream<Void>.makeStream()
        let resumeIterator = Box(resumeStream.stream.makeAsyncIterator())

        let cannedStats = WorktreeStats(ahead: 3, behind: 7, insertions: 40, deletions: 10, hasUncommittedChanges: false)
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _, _ in
            // Suspend until the test signals. This is where the Task
            // "is in-flight" waiting on a git subprocess in production.
            _ = await resumeIterator.value.next()
            return WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: cannedStats)
        }

        let store = WorktreeStatsStore(compute: compute)

        store.refresh(worktreePath: "/wt", repoPath: "/r", branch: "main")
        #expect(store.isInFlightForTesting("/wt"))

        // Clear while compute is suspended — bumps generation.
        store.clear(worktreePath: "/wt")
        #expect(!store.isInFlightForTesting("/wt"))

        // Release compute so its apply can attempt the write.
        resumeStream.continuation.yield(())
        resumeStream.continuation.finish()

        // Wait for apply to run.
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if store.stats["/wt"] != nil { break }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // apply captured generation 0; clear bumped to 1; apply sees
        // mismatch and drops the write. stats must NOT contain "/wt".
        #expect(store.stats["/wt"] == nil,
                "DIVERGE-4.5 violation: apply repopulated stats for cleared worktree")
    }
}

/// Swift 6 doesn't let an AsyncStream.Iterator cross actor boundaries
/// directly — wrap in a Sendable box (unchecked because we only use it
/// in single-reader fashion here).
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
