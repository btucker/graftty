import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct WorkspacePresentationTests {
    @Test("@spec LAYOUT-2.164: When migrating an existing split layout to workspace presentation, the application shall preserve the saved split directions, ratios, and session positions.")
    func legacySplitsRemainInPlace() {
        let a = PaneSlotID(), b = PaneSlotID()
        let tree = SplitTree(root: .split(.init(direction: .vertical, ratio: 0.37, left: .leaf(a), right: .leaf(b))))
        var worktree = WorktreeEntry(path: "/repo", branch: "main", state: .running, splitTree: tree)
        worktree.ensureWorkspaceLayout()
        #expect(worktree.workspaceLayout?.visibleSplitTree == tree)
        #expect(worktree.workspaceLayout?.sessions == [a, b])
    }
    @Test("@spec LAYOUT-2.166: While workspace tabs are active, the application shall use selected tabs and the visible drawer for spatial navigation without including hidden sessions.")
    func navigationUsesVisibleSessions() {
        let a = PaneSlotID(), b = PaneSlotID(), shell = PaneSlotID()
        var worktree = WorktreeEntry(path: "/repo", branch: "main")
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(a); layout.addAgent(b); layout.addTerminal(shell)
        worktree.workspaceLayout = layout
        #expect(worktree.navigationTree.allLeaves == [b, shell])
        _ = worktree.workspaceLayout?.hideDrawer()
        #expect(worktree.navigationTree.allLeaves == [b])
    }

}
