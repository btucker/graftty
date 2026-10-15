import Testing
@testable import GrafttyKit
@testable import Graftty

@Suite("Auto-tracking context menu")
struct AutoTrackingMenuTests {
    @Test("@spec GIT-6.6: While an on-disk Git worktree is the main checkout or an explicitly pinned agent, the application shall offer an auto-tracking context-menu toggle that is checked when enabled and labeled Auto-Track Remote for the main checkout or Auto-Track Default Branch for linked agents.")
    func onlyEligibleWorktreesHaveToggle() {
        let repo = RepoEntry(path: "/repo", displayName: "Repo")
        var home = WorktreeEntry(path: repo.path, branch: "trunk")
        var role = WorktreeEntry(path: "/repo/role", branch: "role")
        #expect(GitAutoTracking.menuTitle(worktree: home, repo: repo) == "Auto-Track Remote")
        #expect(GitAutoTracking.menuTitle(worktree: role, repo: repo) == nil)
        role.isPinned = true
        #expect(GitAutoTracking.menuTitle(worktree: role, repo: repo) == "Auto-Track Default Branch")
        for state in [WorktreeState.stale, .creating, .deleting] {
            home.state = state
            role.state = state
            #expect(GitAutoTracking.menuTitle(worktree: home, repo: repo) == nil)
            #expect(GitAutoTracking.menuTitle(worktree: role, repo: repo) == nil)
        }
        var folder = repo
        folder.isGitTracked = false
        home.state = .running
        #expect(GitAutoTracking.menuTitle(worktree: home, repo: folder) == nil)
    }

    @Test func staleMenuCannotEnableTrackingOnUnpinnedAgent() {
        var role = WorktreeEntry(path: "/repo/role", branch: "role")
        role.isPinned = true
        var repos = [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [role])]
        #expect(GitAutoTracking.setEnabled(true, worktreeID: role.id, in: &repos))
        #expect(repos[0].worktrees[0].autoTrackEnabled)
        repos[0].worktrees[0].isPinned = false
        #expect(!GitAutoTracking.setEnabled(true, worktreeID: role.id, in: &repos))
    }
}
