import Foundation
import Testing
@testable import GrafttyKit

@Suite("RepoTeardown")
struct RepoTeardownTests {
    @MainActor
    @Test func clearsRemoteBranchSnapshotForRepo() async throws {
        let remoteBranchStore = RemoteBranchStore(list: { _ in ["feature"] })
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }

        RepoTeardown.stopWatchersAndClearCaches(
            repo: RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [WorktreeEntry(path: "/repo/wt", branch: "feature")]
            ),
            worktreeMonitor: WorktreeMonitor(),
            statsStore: WorktreeStatsStore(),
            prStatusStore: PRStatusStore(),
            remoteBranchStore: remoteBranchStore
        )

        #expect(!remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature"))
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @MainActor @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let succeeded = await condition()
        #expect(succeeded, "waitUntil timed out")
    }
}
