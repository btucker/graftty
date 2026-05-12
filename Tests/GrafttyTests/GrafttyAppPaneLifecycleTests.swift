import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("GrafttyApp pane lifecycle")
struct GrafttyAppPaneLifecycleTests {

    @Test func reassignPaneByPWDMovesPaneSessionToTargetWorktree() {
        let slot = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)
        let session = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!)
        var source = WorktreeEntry(path: "/repo/source", branch: "source", state: .running)
        source.splitTree = SplitTree(root: .leaf(slot))
        source.focusedTerminalID = slot
        source.paneSessions[slot] = session
        let target = WorktreeEntry(path: "/repo/target", branch: "target", state: .closed)
        var state = AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [source, target]
                )
            ],
            selectedWorktreePath: source.path
        )
        let binding = Binding<AppState>(
            get: { state },
            set: { state = $0 }
        )
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")

        GrafttyApp.reassignPaneByPWD(
            appState: binding,
            terminalManager: manager,
            terminalID: slot,
            newPWD: "/repo/target/subdir"
        )

        let movedSource = state.repos[0].worktrees[0]
        let movedTarget = state.repos[0].worktrees[1]
        #expect(movedSource.paneSessions[slot] == nil)
        #expect(movedTarget.paneSessions[slot] == session)
        #expect(movedTarget.splitTree.containsLeaf(slot))
    }
}
