import Testing
@testable import Graftty

@Suite("Flow State sidebar selection")
struct SidebarFlowStateTests {
    @Test("Selecting Flow State preserves the current worktree path.")
    func selectingFlowStateDoesNotMutateWorktreePath() {
        let transition = MainWindowSelectionTransition.selectFlowState(
            currentWorktreePath: "/repo/worktrees/feature"
        )

        #expect(transition.selection == .flowState)
        #expect(transition.selectedWorktreePath == "/repo/worktrees/feature")
    }

    @Test("Selecting a worktree leaves Flow State mode.")
    func selectingWorktreeClearsFlowStateMode() {
        let transition = MainWindowSelectionTransition.selectWorktree("/repo/worktrees/fix")

        #expect(transition.selection == .worktree("/repo/worktrees/fix"))
        #expect(transition.selectedWorktreePath == "/repo/worktrees/fix")
    }
}
