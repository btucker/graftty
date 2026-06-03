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
        if case let .leaf(sessionName, title, _, _, _) = layout {
            return .session(sessionName: sessionName, title: title)
        }
        return .worktreeDetail
    }

    /// @spec IOS-4.21
    /// Pane child rows under a multi-leaf worktree always navigate
    /// straight to the fullscreen terminal, never to the worktree-
    /// detail / pane-preview screen.
    public static func decide(paneRow leaf: PaneLayoutNode.Leaf) -> MobileNavigationDecision {
        .session(sessionName: leaf.sessionName, title: leaf.title)
    }
}
