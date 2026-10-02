import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct SidebarLocalWorktreeIdentityTests {
    @Test func localSnapshotUsesWorktreeLabelAndKeepsBranchSeparate() throws {
        let worktree = WorktreeEntry(path: "/repo/.worktrees/research/lead", branch: "feature/different")
        let state = AppState(repos: [.init(path: "/repo", displayName: "Repo", worktrees: [worktree])])
        let owner = WorktreeOrigin(deviceID: .init(value: "local"), deviceLabel: "Mac", relayDepth: 0)
        let row = try #require(sidebarLocalWorktrees(state: state, owner: owner, titles: [:], liveness: [:]).first)
        #expect(row.displayName == "research/lead")
        #expect(row.displayBranch == "feature/different")
    }
}
