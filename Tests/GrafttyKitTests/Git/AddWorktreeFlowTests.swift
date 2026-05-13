import Testing
import Foundation
@testable import GrafttyKit

@Suite("RepoEntry.branchMountedPath")
struct RepoEntryBranchMountedTests {
    @Test("returns path when branch is in an on-disk worktree")
    func returnsPathForOnDisk() {
        var wt = WorktreeEntry(path: "/r/.worktrees/feat", branch: "feat")
        wt.state = .running
        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [wt]
        )
        #expect(repo.branchMountedPath("feat") == "/r/.worktrees/feat")
    }

    @Test("returns nil for .creating placeholder")
    func nilForCreatingPlaceholder() {
        var wt = WorktreeEntry(path: "/r/.worktrees/feat", branch: "feat")
        wt.state = .creating
        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [wt]
        )
        #expect(repo.branchMountedPath("feat") == nil)
    }

    @Test("returns nil when no worktree matches the branch")
    func nilWhenNotMounted() {
        var wt = WorktreeEntry(path: "/r/.worktrees/other", branch: "other")
        wt.state = .running
        let repo = RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [wt]
        )
        #expect(repo.branchMountedPath("feat") == nil)
    }
}
