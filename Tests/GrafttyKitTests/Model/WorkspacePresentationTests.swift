import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct WorkspacePresentationTests {
    @Test("@spec LAYOUT-2.173: When focus moves to a different canvas group while another pane is zoomed, the application shall reveal the focused pane and retain zoom only when it is explicitly rebound to that pane.")
    func externalFocusRevealsAnotherGroup() {
        let a = PaneSlotID(), b = PaneSlotID()
        let tree = SplitTree(root: .leaf(a)).inserting(b, at: a, direction: .horizontal)
        var worktree = WorktreeEntry(path: "/repo", branch: "main", splitTree: tree.withZoom(a))
        worktree.workspaceLayout = .preserving(tree)
        worktree.focusedPaneSlotID = a
        #expect(worktree.canvasTree.zoomed == a)
        worktree.focusedPaneSlotID = b
        #expect(worktree.canvasTree.zoomed == nil)
        #expect(worktree.visiblePaneSlots == [a, b])
        worktree.splitTree = tree.withZoom(b)
        #expect(worktree.canvasTree.zoomed == b)
    }

    @Test("@spec LAYOUT-2.176: When cleanup removes the viewed agent's live pane binding, the application shall retain that agent's completed view using its stable agent identity and shall not replace it when another agent closes.")
    func archiveUsesStableAgentIdentity() throws {
        let a = PaneSlotID(), b = PaneSlotID()
        var first = ManagedAgent(name: "First", provider: .codex, parent: nil)
        var other = ManagedAgent(name: "Other", provider: .claude, parent: nil)
        first.paneSlotID = a; other.paneSlotID = b
        let previous = [first, other]
        let completion = try first.finish(assignment: first.assignmentID, result: "Done")
        try first.beginClose(completion: completion.id)
        first.paneSlotID = nil
        let closing = first
        first.didClose()
        var worktree = WorktreeEntry(path: "/repo", branch: "main")
        worktree.agents = [first, other]
        #expect(worktree.newlyClosedAgent(viewedAgentID: first.id, previousAgents: [closing, other])?.id == first.id)
        #expect(worktree.newlyClosedAgent(viewedAgentID: other.id, previousAgents: previous) == nil)
        #expect(worktree.newlyClosedAgent(viewedAgentID: nil, previousAgents: previous) == nil)
        #expect(worktree.newlyClosedAgent(viewedAgentID: first.id, previousAgents: worktree.agents) == nil)
    }

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

    @Test("@spec LAYOUT-2.169: While workspace tabs or a terminal drawer are hidden, the application shall restore visibility only for the selected canvas panes and the open drawer, including after zoom changes.")
    func visibilityExcludesHiddenTabsAndDrawer() {
        let a = PaneSlotID(), b = PaneSlotID(), shell = PaneSlotID()
        var worktree = WorktreeEntry(path: "/repo", branch: "main")
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(a); layout.addAgent(b); layout.addTerminal(shell)
        worktree.workspaceLayout = layout
        worktree.splitTree = SplitTree(root: .leaf(a)).inserting(b, at: a, direction: .horizontal)
            .inserting(shell, at: b, direction: .vertical).withZoom(shell)
        #expect(worktree.canvasTree.zoomed == nil)
        #expect(worktree.visiblePaneSlots == [b, shell])
        worktree.splitTree = worktree.splitTree.withZoom(a)
        #expect(worktree.canvasTree.zoomed == nil)
        _ = worktree.workspaceLayout?.hideDrawer()
        #expect(worktree.visiblePaneSlots == [b])
        worktree.workspaceLayout?.select(a)
        #expect(worktree.canvasTree.zoomed == a)
        #expect(worktree.visiblePaneSlots == [a])
    }

}
