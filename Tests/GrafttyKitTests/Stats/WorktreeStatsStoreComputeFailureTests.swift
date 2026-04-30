import Testing
import Foundation
@testable import GrafttyKit

/// Mirrors `PR-7.7` for divergence stats: when `compute` fails after
/// the default branch has been resolved (a transient `git rev-list`
/// failure, broken ref, FS permission blip), the last-known stats
/// must stay in place. Wiping the ↑N ↓M badge on every failed poll
/// makes the sidebar divergence gutter flicker whenever the repo's
/// git state is briefly unhealthy.
@Suite("""
WorktreeStatsStore — compute-failure cache preservation

@spec DIVERGE-4.9: When a compute attempt fails transiently (the default branch was resolvable but `git rev-list`/`diff-tree`/etc. threw), the application shall preserve the worktree's last-known `WorktreeStats` rather than clearing the sidebar gutter. Only when the repo has no resolvable default branch at all (origin removed, clone converted to non-origin setup) shall the stats be wiped. Without this, the ↑N ↓M badge flickers off for the polling window whenever git is briefly unhealthy — same UX concern as `PR-7.10`.
""")
struct WorktreeStatsStoreComputeFailureTests {

    @MainActor
    @Test func computeFailureKeepsLastKnownStats() async throws {
        // Two-stage compute: returns real stats on call 1, then
        // mimics a transient failure (defaultBranch resolved but
        // stats nil — what `try? GitWorktreeStats.compute(...)`
        // returns when the subprocess throws) on call 2.
        let callCount = SyncCounter()
        let okStats = WorktreeStats(ahead: 3, behind: 2, insertions: 0, deletions: 0)
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _, _ in
            let n = callCount.incrementAndGet()
            if n == 1 {
                return WorktreeStatsStore.ComputeResult(
                    defaultBranch: "main",
                    stats: okStats
                )
            } else {
                // Default branch still resolvable (so we know this
                // isn't the "repo has no default branch" case), but
                // stats compute threw — `try?` swallowed it.
                return WorktreeStatsStore.ComputeResult(
                    defaultBranch: "main",
                    stats: nil
                )
            }
        }

        let store = WorktreeStatsStore(
            compute: compute,
            fetch: { _ in }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")
        for _ in 0..<100 {
            if store.stats["/wt"] == okStats { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.stats["/wt"] == okStats, "first compute publishes stats")

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")
        try await Task.sleep(for: .milliseconds(120))

        #expect(
            store.stats["/wt"] == okStats,
            "compute failure with resolved defaultBranch must preserve last-known stats"
        )
    }

    @MainActor
    @Test func missingDefaultBranchStillWipesStats() async throws {
        // Counterpart: when compute reports no default branch at all
        // (repo has no `origin/main`-like ref), wiping is correct —
        // there's no divergence to show. This pins the distinction so
        // the fix can't over-correct.
        let callCount = SyncCounter()
        let okStats = WorktreeStats(ahead: 1, behind: 0, insertions: 0, deletions: 0)
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _, _ in
            let n = callCount.incrementAndGet()
            if n == 1 {
                return WorktreeStatsStore.ComputeResult(
                    defaultBranch: "main",
                    stats: okStats
                )
            } else {
                // No default branch this time — legitimately nothing
                // to compare against (user removed origin, etc.).
                return WorktreeStatsStore.ComputeResult(
                    defaultBranch: nil,
                    stats: nil
                )
            }
        }

        let store = WorktreeStatsStore(
            compute: compute,
            fetch: { _ in }
        )

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")
        for _ in 0..<100 {
            if store.stats["/wt"] == okStats { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.stats["/wt"] == okStats)

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")
        try await Task.sleep(for: .milliseconds(120))

        #expect(
            store.stats["/wt"] == nil,
            "missing default branch → no divergence to show, wipe is correct"
        )
    }
}

/// Tiny thread-safe counter so the `@Sendable` compute closure can
/// track invocation count without pulling in Foundation's locking
/// ceremony at every call site.
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
