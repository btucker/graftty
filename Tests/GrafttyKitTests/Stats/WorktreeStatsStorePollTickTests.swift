import Testing
import Foundation
@testable import GrafttyKit

/// DIVERGE-4.6: the polling tick must recompute divergence stats per
/// worktree on its own 30s cadence, NOT only after a successful repo
/// `git fetch`. Before cycle 143, `pollTick` only ever called
/// `store.refresh` from inside `performRepoFetch`, so a repo whose
/// 5-minute fetch window hadn't elapsed left local working-tree
/// changes (a `git add` in an external shell, a commit made by a tool
/// other than Graftty) stale in the sidebar for up to the full fetch
/// window.
@Suite("""
WorktreeStatsStore.pollTick

@spec DIVERGE-4.6: The polling loop shall also recompute divergence counts for every non-stale worktree on a 30-second per-worktree cadence, independent of the network `git fetch` cadence in DIVERGE-4.3. Local-only recomputation uses no network — `git rev-list`, `git diff --shortstat`, and `git status --porcelain` all run against the local object store — so it catches local changes (a `git add` in an external shell, a commit made by a tool other than Graftty) even when the repo's fetch cooldown is still active. When a tick finds a per-repo fetch is due in the same cycle, the per-worktree cadence is skipped for that repo because the fetch handler itself recomputes every worktree on success.
""")
struct WorktreeStatsStorePollTickTests {

    @MainActor
    @Test func pollTickRefreshesWorktreeEvenWhenFetchCooldownActive() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        // Fresh repo-fetch timestamp → 5-min fetch cadence NOT elapsed.
        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        // No `lastStatsRefresh` seed for the worktree → its 30s cadence
        // IS elapsed (vacuously), so pollTick's Gate B must dispatch.

        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [WorktreeEntry(path: "/r/wt", branch: "feature")]
        )
        await store.pollTickForTesting(repos: [repo])

        // compute is invoked on a detached Task from pollTick; wait for
        // the Task to schedule and the RecordingCompute to observe it.
        try await waitUntil(timeout: 2.0) { compute.calledPaths.contains("/r/wt") }
    }

    @MainActor
    @Test func pollTickSkipsWorktreeWhenBothGatesAreFresh() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        // Both gates fresh: fetch cooldown active AND stats cooldown active.
        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        store.seedLastStatsRefreshForTesting(Date(), forWorktree: "/r/wt")

        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [WorktreeEntry(path: "/r/wt", branch: "feature")]
        )
        await store.pollTickForTesting(repos: [repo])

        // Give a detached Task a chance to land if it were going to.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!compute.calledPaths.contains("/r/wt"),
                "fresh stats cadence must gate the local recompute")
    }

    @MainActor
    @Test func pollTickSkipsStaleWorktrees() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        // No stats-cadence seed → gate would otherwise fire, but the
        // worktree is stale so it must be skipped (PR-7.4 / DIVERGE-1.6
        // parity — stale entries render no stats indicator and the
        // polling loop must not compute against a path that no longer
        // exists on disk).
        var staleWt = WorktreeEntry(path: "/r/gone", branch: "feature")
        staleWt.state = .stale
        let repo = RepoEntry(path: "/r", displayName: "r", worktrees: [staleWt])

        await store.pollTickForTesting(repos: [repo])
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!compute.calledPaths.contains("/r/gone"))
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(condition(), "waitUntil timed out")
    }
}

/// Thread-safe recorder for injected `ComputeFunction` invocations.
/// A plain class + `NSLock` is deliberately simpler than an actor here:
/// the `@Sendable` compute closure needs to be callable from a detached
/// Task while the @MainActor test asserts — an actor-isolated getter
/// would force the test to await every observation and the `function`
/// property itself would become actor-isolated.
private final class RecordingCompute: @unchecked Sendable {
    private let lock = NSLock()
    private var _calledPaths: Set<String> = []

    var calledPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _calledPaths
    }

    var function: WorktreeStatsStore.ComputeFunction {
        { [weak self] worktreePath, _, _, _ in
            self?.record(worktreePath)
            return WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
        }
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _calledPaths.insert(path)
    }
}
