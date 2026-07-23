import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("GrafttyApp pane navigation")
struct GrafttyAppPaneNavigationTests {
    @Test("tree-order pane navigation wraps in both directions")
    func paneNavigationWraps() {
        let first = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        let second = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        var worktree = WorktreeEntry(path: "/repo/wt", branch: "wt", state: .running)
        worktree.splitTree = SplitTree(root: .split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(first),
            right: .leaf(second)
        )))
        worktree.focusedPaneSlotID = second
        var state = AppState(
            repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])],
            selectedWorktreePath: worktree.path
        )
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-pane-navigation-test.sock")

        GrafttyApp.navigatePaneInTreeOrder(
            appState: binding,
            terminalManager: manager,
            from: second,
            forward: true
        )
        #expect(state.repos[0].worktrees[0].focusedPaneSlotID == first)

        GrafttyApp.navigatePaneInTreeOrder(
            appState: binding,
            terminalManager: manager,
            from: first,
            forward: false
        )
        #expect(state.repos[0].worktrees[0].focusedPaneSlotID == second)
    }

    @Test("tree-order navigation is a no-op for one pane")
    func singlePaneIsNoOp() {
        let only = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        var worktree = WorktreeEntry(path: "/repo/wt", branch: "wt", state: .running)
        worktree.splitTree = SplitTree(root: .leaf(only))
        worktree.focusedPaneSlotID = only
        var state = AppState(
            repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])],
            selectedWorktreePath: worktree.path
        )
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-pane-navigation-test.sock")

        GrafttyApp.navigatePaneInTreeOrder(
            appState: binding,
            terminalManager: manager,
            from: only,
            forward: true
        )

        #expect(state.repos[0].worktrees[0].focusedPaneSlotID == only)
    }
}
