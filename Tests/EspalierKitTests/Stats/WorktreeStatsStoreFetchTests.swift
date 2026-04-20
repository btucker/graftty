import Testing
import Foundation
@testable import EspalierKit

/// Pre-cycle-140, `WorktreeStatsStore.performRepoFetch` called
/// `GitRunner.captureAll` — which returns normally on non-zero exit —
/// and only entered the catch block on LAUNCH failures (git binary
/// missing, subprocess error). A real-world `git fetch` that exited
/// non-zero (offline, auth revocation, remote unreachable, rate-limited)
/// was silently treated as success: `repoFailureStreak` reset to 0, and
/// `ExponentialBackoff` never kicked in. Espalier kept hammering
/// `git fetch` every 5 minutes even when it was consistently failing.
///
/// Cycle 140 swapped the internal call to a `FetchFunction` closure
/// that defaults to `GitRunner.run` (which throws on non-zero exit).
/// These tests pin the streak behavior via the injected closure so the
/// streak/backoff contract can't silently regress again.
@Suite("WorktreeStatsStore fetch-failure streak")
struct WorktreeStatsStoreFetchTests {

    @MainActor
    @Test func successfulFetchKeepsStreakAtZero() async {
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _ in
            WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
        }
        let fetch: WorktreeStatsStore.FetchFunction = { _, _ in
            // No-op success.
        }
        let store = WorktreeStatsStore(compute: compute, fetch: fetch)
        store.seedDefaultBranchForTesting("main", forRepo: "/r")
        #expect(store.repoFailureStreakForTesting("/r") == 0)

        await store.performRepoFetchForTesting(repoPath: "/r", worktreePaths: [])

        #expect(store.repoFailureStreakForTesting("/r") == 0,
                "successful fetch must leave the streak alone")
    }

    @MainActor
    @Test func throwingFetchIncrementsStreak() async {
        // This is the regression target: a `git fetch` that throws
        // (non-zero exit) must be treated as a failure, not as success.
        struct StubError: Error {}
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _ in
            WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
        }
        let fetch: WorktreeStatsStore.FetchFunction = { _, _ in
            throw StubError()
        }
        let store = WorktreeStatsStore(compute: compute, fetch: fetch)
        store.seedDefaultBranchForTesting("main", forRepo: "/r")

        await store.performRepoFetchForTesting(repoPath: "/r", worktreePaths: [])

        #expect(store.repoFailureStreakForTesting("/r") == 1,
                "a throwing fetch must increment the streak so exponential backoff kicks in")
    }

    @MainActor
    @Test func repeatedFailuresAccumulate() async {
        struct StubError: Error {}
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _ in
            WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
        }
        let fetch: WorktreeStatsStore.FetchFunction = { _, _ in
            throw StubError()
        }
        let store = WorktreeStatsStore(compute: compute, fetch: fetch)
        store.seedDefaultBranchForTesting("main", forRepo: "/r")

        for expected in 1...5 {
            await store.performRepoFetchForTesting(repoPath: "/r", worktreePaths: [])
            #expect(store.repoFailureStreakForTesting("/r") == expected)
        }
    }

    @MainActor
    @Test func recoveryAfterFailureResetsStreak() async {
        // Proves the streak is NOT sticky — once fetch succeeds again,
        // backoff disengages.
        struct StubError: Error {}
        let compute: WorktreeStatsStore.ComputeFunction = { _, _, _ in
            WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
        }
        // Per-call behavior: first two calls throw, third succeeds.
        let callCount = IntBox()
        let fetch: WorktreeStatsStore.FetchFunction = { _, _ in
            callCount.value += 1
            if callCount.value < 3 { throw StubError() }
        }
        let store = WorktreeStatsStore(compute: compute, fetch: fetch)
        store.seedDefaultBranchForTesting("main", forRepo: "/r")

        await store.performRepoFetchForTesting(repoPath: "/r", worktreePaths: [])
        await store.performRepoFetchForTesting(repoPath: "/r", worktreePaths: [])
        #expect(store.repoFailureStreakForTesting("/r") == 2)

        await store.performRepoFetchForTesting(repoPath: "/r", worktreePaths: [])
        #expect(store.repoFailureStreakForTesting("/r") == 0,
                "streak resets on first successful fetch")
    }
}

/// Tiny mutable Int holder for closures that need shared state.
private final class IntBox: @unchecked Sendable {
    var value: Int = 0
}
