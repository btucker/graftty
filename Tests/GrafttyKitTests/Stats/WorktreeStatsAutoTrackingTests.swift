import Foundation
import Testing
@testable import GrafttyKit

@Suite("Worktree stats auto-tracking integration")
@MainActor
struct WorktreeStatsAutoTrackingTests {
    @Test func linkedMergeRefreshesOnlyItsOwnStats() async throws {
        let state = State()
        var sibling = WorktreeEntry(path: "/repo/sibling", branch: "sibling", state: .running)
        sibling.isPinned = true
        state.repos[0].worktrees.append(sibling)
        let tracker = GitAutoTracking(readSnapshot: { _ in state.snapshot }, perform: { _ in true })
        let store = makeStore(state: state, tracker: tracker)
        store.refreshAutoTracking(repoPath: state.repo.path)
        try await waitUntil { store.stats["/repo/role"] != nil }
        #expect(store.generationForTesting("/repo/sibling") == 0)
        store.stop()
    }

    @Test func unpinClearsClosedAgentsFormerLocalDefaultStats() async throws {
        let state = State()
        let tracker = GitAutoTracking(readSnapshot: { _ in state.snapshot }, perform: { _ in true })
        let store = makeStore(state: state, tracker: tracker)
        store.seedLastRepoFetchForTesting(Date(), forRepo: state.repo.path)
        store.refresh(worktreePath: "/repo/role", repoPath: "/repo", branch: "role")
        try await waitUntil { store.stats["/repo/role"]?.behind == 2 }
        #expect(SidebarHostNavigation.setPinned(false, worktreeID: state.repo.worktrees[1].id, in: &state.repos))
        await store.pollTickForTesting(repos: state.repos)
        #expect(store.stats["/repo/role"] == nil)
        store.stop()
    }

    @Test func pollingTracksClosedPinnedAgentsAndRefreshesLocalStats() async throws {
        let state = State()
        var operations: [GitAutoTracking.Operation] = []
        let tracker = GitAutoTracking(readSnapshot: { _ in state.snapshot }, perform: { operations.append($0); return true })
        let store = makeStore(state: state, tracker: tracker)
        store.seedLastRepoFetchForTesting(Date(), forRepo: state.repo.path)

        await store.pollTickForTesting(repos: [state.repo])
        try await waitUntil { store.stats["/repo/role"]?.behind == 2 && operations.count == 1 }
        #expect(operations == [.merge(path: "/repo/role", branch: "trunk")])
        #expect(state.repo.worktrees[1].autoTrackLastAttempt?.commit == "local")
        store.refreshAutoTracking(repoPath: state.repo.path)
        await store.pollTickForTesting(repos: [state.repo])
        try await Task.sleep(for: .milliseconds(50))
        #expect(operations.count == 1)

        #expect(GitAutoTracking.setEnabled(false, worktreeID: state.repo.worktrees[1].id, in: &state.repos))
        store.refresh(worktreePath: "/repo/role", repoPath: "/repo", branch: "role")
        try await waitUntil { store.stats["/repo/role"]?.behind == 0 }
        #expect(state.repo.worktrees[1].autoTrackLastAttempt == nil)
        store.stop()
    }

    @Test func postFetchTrackingSeesNewRemoteTarget() async throws {
        let state = State()
        state.repos[0].worktrees[0].autoTrackEnabled = true
        var operations: [GitAutoTracking.Operation] = []
        let tracker = GitAutoTracking(readSnapshot: { _ in state.snapshot }, perform: { operations.append($0); return true })
        let store = makeStore(state: state, tracker: tracker, fetch: { _ in
            await MainActor.run {
                state.snapshot = .init(branch: "trunk", localCommit: "local", remoteCommit: "fetched")
            }
        })
        // Seed the resolved default through the injected compute pipeline.
        store.refresh(worktreePath: "/repo", repoPath: "/repo", branch: "trunk")
        try await waitUntil { store.stats["/repo"] != nil }
        await store.pollTickForTesting(repos: [state.repo])
        try await waitUntil { state.repo.worktrees[0].autoTrackLastAttempt?.commit == "fetched" }
        #expect(operations.contains(.pull(path: "/repo", branch: "trunk")))
        store.stop()
    }

    private func makeStore(
        state: State,
        tracker: GitAutoTracking,
        fetch: @escaping WorktreeStatsStore.FetchFunction = { _ in }
    ) -> WorktreeStatsStore {
        let store = WorktreeStatsStore(compute: { _, _, _, _ in
            .init(defaultBranch: "trunk", stats: .init(ahead: 0, behind: 0, insertions: 0, deletions: 0))
        }, fetch: fetch, autoTracking: tracker, computeLocalDefault: { _, _, _, _, _ in
            .init(defaultBranch: "trunk", stats: .init(ahead: 0, behind: 2, insertions: 0, deletions: 0,
                                                      upstreamRefs: .init(defaultRef: "refs/heads/trunk")))
        })
        store.start(ticker: PassiveAutoTrackingTicker(), getRepos: { state.repos }, recordAutoTrackingAttempt: { path, target in
            guard let index = state.repos[0].worktrees.firstIndex(where: { $0.path == path }) else { return }
            state.repos[0].worktrees[index].autoTrackLastAttempt = target
        })
        return store
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }

    @MainActor
    private final class State {
        var repos: [RepoEntry]
        var repo: RepoEntry { repos[0] }
        var snapshot = GitAutoTracking.Snapshot(branch: "trunk", localCommit: "local", remoteCommit: "remote")

        init() {
            let home = WorktreeEntry(path: "/repo", branch: "trunk")
            var role = WorktreeEntry(path: "/repo/role", branch: "role")
            role.isPinned = true
            role.autoTrackEnabled = true
            repos = [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [home, role])]
        }
    }
}

@MainActor
private final class PassiveAutoTrackingTicker: PollingTickerLike {
    func start(onTick: @MainActor @escaping () async -> Void) {}
    func stop() {}
    func pulse() {}
}
