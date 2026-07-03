import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("FlowState command routing")
struct FlowStateCommandRoutingTests {
    @Test("pane commands no-op while Flow State is selected instead of targeting the preserved worktree")
    func flowStateSelectionDoesNotUsePreservedWorktreePane() {
        let worktreePane = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000081")!)
        let flowPane = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000082")!)

        let target = MainWindowPaneCommandTarget.resolve(
            selection: .flowState,
            selectedWorktreeFocusedPane: worktreePane,
            flowStateFocusedPane: flowPane
        )

        #expect(target == nil)
    }

    @Test("pane commands target the selected worktree while a worktree is selected")
    func worktreeSelectionUsesWorktreePane() {
        let worktreePane = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000091")!)
        let flowPane = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000092")!)

        let target = MainWindowPaneCommandTarget.resolve(
            selection: .worktree("/repo/wt"),
            selectedWorktreeFocusedPane: worktreePane,
            flowStateFocusedPane: flowPane
        )

        #expect(target == worktreePane)
    }
}
