import Foundation
import Testing
@testable import GrafttyKit

@Suite("AppState worktree mutation helpers")
struct AppStateWorktreeMutationTests {
    private func state(_ worktrees: [[WorktreeEntry]]) -> AppState {
        AppState(repos: worktrees.enumerated().map { index, entries in
            var repo = RepoEntry(path: "/repo\(index)", displayName: "repo\(index)")
            repo.worktrees = entries
            return repo
        })
    }

    @Test func mutateWorktreesAtPathUpdatesEveryMatch() {
        var appState = state([
            [WorktreeEntry(path: "/a", branch: "a"), WorktreeEntry(path: "/b", branch: "b")],
            [WorktreeEntry(path: "/a", branch: "a2")],
        ])

        let found = appState.mutateWorktrees(atPath: "/a") { $0.branch += "!" }

        #expect(found)
        #expect(appState.repos[0].worktrees.map(\.branch) == ["a!", "b"])
        #expect(appState.repos[1].worktrees.map(\.branch) == ["a2!"])
    }

    @Test func mutateWorktreesAtPathIgnoresUnknownPath() {
        var appState = state([[WorktreeEntry(path: "/a", branch: "a")]])
        let before = appState

        let found = appState.mutateWorktrees(atPath: "/missing") { $0.branch = "changed" }

        #expect(!found)
        #expect(appState == before)
    }

    @Test func mutateWorktreeContainingLeafUpdatesOnlyFirstOwner() {
        let leaf = PaneSlotID()
        var first = WorktreeEntry(path: "/a", branch: "a")
        first.splitTree = SplitTree(root: .leaf(leaf))
        var second = WorktreeEntry(path: "/b", branch: "b")
        second.splitTree = SplitTree(root: .leaf(leaf))
        var appState = state([[first], [second]])

        let found = appState.mutateWorktree(containing: leaf) { $0.branch += "!" }

        #expect(found)
        #expect(appState.repos[0].worktrees[0].branch == "a!")
        #expect(appState.repos[1].worktrees[0].branch == "b")
    }

    @Test func mutateWorktreeContainingUnknownLeafReportsMiss() {
        var appState = state([[WorktreeEntry(path: "/a", branch: "a")]])

        let found = appState.mutateWorktree(containing: PaneSlotID()) { $0.branch = "changed" }

        #expect(!found)
        #expect(appState.repos[0].worktrees[0].branch == "a")
    }
}
