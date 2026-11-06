import GrafttyCommandUI
import GrafttyProtocol

/// Pure navigation decision for the worktree picker → next-screen push.
/// IOS-4.17: when a worktree's pane layout is a single leaf, skip the
/// pane-tree screen and push the fullscreen session directly. Split
/// layouts and the no-panes (nil-layout) case still go through the
/// worktree-detail screen.
public enum MobileNavigationDecision: Equatable {
    case session(sessionName: String, title: String)
    case worktreeDetail

    public static func decide(layout: PaneLayoutNode?) -> MobileNavigationDecision {
        if case let .leaf(sessionName, title, _, _, _, _) = layout {
            return .session(sessionName: sessionName, title: title)
        }
        return .worktreeDetail
    }

    /// A row tap: open the agent that most needs the person, because the agent
    /// dropdown reaches the others. Without agents there's no dropdown, so
    /// several panes still get the pane screen.
    @MainActor
    public static func decide(worktree: WorktreePanes, context: SidebarWorktreeContext) -> MobileNavigationDecision {
        guard let agent = MobileWorktreeOverview(worktree: worktree, context: context).agents.first else {
            return decide(layout: worktree.layout)
        }
        return .session(sessionName: agent.session, title: agent.title)
    }

    /// @spec IOS-4.21
    /// A pane opened from an attention request always navigates
    /// straight to the fullscreen terminal, never to the worktree-
    /// detail / pane-preview screen.
    public static func decide(paneRow leaf: PaneLayoutNode.Leaf) -> MobileNavigationDecision {
        .session(sessionName: leaf.sessionName, title: leaf.title)
    }
}
