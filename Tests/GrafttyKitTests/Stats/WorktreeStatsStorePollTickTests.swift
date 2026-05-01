import Testing
import Foundation
@testable import GrafttyKit

/// DIVERGE-4.6: the polling tick must recompute divergence stats for
/// every running worktree on every 5-second tick, with no per-worktree
/// throttle. Before this simplification, `pollTick` gated each worktree
/// behind a 30-second `lastStatsRefresh` clock — so an FSEvents-driven
/// refresh that bumped the clock could leave a worktree stale for up to
/// 30 seconds if a follow-up event was coalesced or fired on a path the
/// watcher wasn't listening on. Collapsing the cadence to a single 5s
/// loop (with `inFlight` as the only in-tick guard) keeps the divergence
/// gutter from going stale after a merge of `origin/<default>` into a
/// feature branch when the FSEvents path missed the change.
@Suite("""
WorktreeStatsStore.pollTick

@spec DIVERGE-4.6: When the divergence-stats polling tick fires, the application shall recompute divergence counts for every running worktree, with no per-worktree throttle beyond the `inFlight` dedup guard from `DIVERGE-4.4` — the local subprocess pipeline (`git rev-list`, `git diff --shortstat`, `git status --porcelain`) is cheap and bounded, so the gutter never stays stale waiting for a per-worktree cooldown to elapse. If the same tick finds a per-repo `git fetch` is due, the per-worktree dispatch shall be skipped for that repo because the fetch handler itself recomputes every running worktree on success.
""")
struct WorktreeStatsStorePollTickTests {

    @MainActor
    @Test func pollTickRefreshesRunningWorktreeOnEveryTickWithNoPerWorktreeThrottle() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        // Repo-fetch cooldown is fresh (so Gate B is the path under
        // test). The simplified model has no per-worktree throttle —
        // every tick refreshes every running worktree. Two ticks in a
        // row must dispatch two refreshes (modulo `inFlight` dedup,
        // which clears between ticks because the injected compute
        // returns synchronously).
        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")

        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [WorktreeEntry(path: "/r/wt", branch: "feature", state: .running)]
        )

        await store.pollTickForTesting(repos: [repo])
        try await waitUntil(timeout: 2.0) { compute.callCount(for: "/r/wt") >= 1 }

        // Wait for the first compute Task to clear `inFlight` via apply().
        let inFlightCleared: () async -> Bool = { @MainActor in
            !store.isInFlightForTesting("/r/wt")
        }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await inFlightCleared() { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(await inFlightCleared())

        await store.pollTickForTesting(repos: [repo])
        try await waitUntil(timeout: 2.0) { compute.callCount(for: "/r/wt") >= 2 }
    }

    @MainActor
    @Test func pollTickSkipsStaleWorktrees() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        // The unconditional per-worktree dispatch would otherwise fire,
        // but the worktree is stale so it must be skipped (PR-7.4 /
        // DIVERGE-1.6 parity — stale entries render no stats indicator
        // and the polling loop must not compute against a path that no
        // longer exists on disk).
        var staleWt = WorktreeEntry(path: "/r/gone", branch: "feature")
        staleWt.state = .stale
        let repo = RepoEntry(path: "/r", displayName: "r", worktrees: [staleWt])

        await store.pollTickForTesting(repos: [repo])
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!compute.calledPaths.contains("/r/gone"))
    }

    @MainActor
    @Test("""
@spec PERF-1.3: The stats polling loop shall skip closed worktrees during its recurring local recompute cadence; a closed worktree exists on disk but has no live terminal surface, and repeatedly running local git scans for every tracked-but-closed row makes CPU scale with sidebar history rather than active work.
""")
    func pollTickSkipsClosedWorktrees() async throws {
        let compute = RecordingCompute()
        let store = WorktreeStatsStore(compute: compute.function, fetch: { _ in })

        store.seedLastRepoFetchForTesting(Date(), forRepo: "/r")
        let closedWt = WorktreeEntry(path: "/r/closed", branch: "feature", state: .closed)
        let repo = RepoEntry(path: "/r", displayName: "r", worktrees: [closedWt])

        await store.pollTickForTesting(repos: [repo])
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!compute.calledPaths.contains("/r/closed"))
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
    private var _callCounts: [String: Int] = [:]

    var calledPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _calledPaths
    }

    func callCount(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _callCounts[path, default: 0]
    }

    var function: WorktreeStatsStore.ComputeFunction {
        { [weak self] worktreePath, _, _, _ in
            self?.record(worktreePath)
            // Return a non-nil stats so apply() clears the in-flight
            // gate — the second-tick assertion needs the slot freed.
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0)
            )
        }
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _calledPaths.insert(path)
        _callCounts[path, default: 0] += 1
    }
}
