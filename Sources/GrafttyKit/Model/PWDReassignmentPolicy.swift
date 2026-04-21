import Foundation

/// Pure policy for deciding whether a `reassignPaneByPWD` event should also
/// carry the user's selection + focus into the destination worktree.
///
/// Historical context: `PWD-2.3` originally promised to "follow the pane the
/// user is actively typing into," but the implementation fired on every
/// reassignment — including ones triggered by background panes (e.g. a
/// claude-code session `cd`ing while the user was looking at a different
/// worktree). With 3–6 concurrent claude sessions (Andy's target workload)
/// this made the selected worktree hop around autonomously. Fix: gate the
/// follow-through on "was the reassigned pane the user's active typing
/// target at the moment of the move?"
///
/// The pane is still MOVED between worktrees regardless of this policy —
/// `PWD-2.1` / `PWD-2.2` mutations happen unconditionally so the sidebar
/// always reflects where each shell now lives. This policy only controls
/// the follow-the-selection step.
public enum PWDReassignmentPolicy {

    /// True when the reassigned pane was the focused pane of the
    /// currently-selected worktree — i.e. the user's keystrokes were
    /// routing to it just before the move. In that case, the selection
    /// and focus follow the pane to the destination. Otherwise the user
    /// stays put.
    public static func shouldFollowToDestination(
        selectedWorktreePath: String?,
        sourceWorktreePath: String,
        sourceFocusedTerminalID: TerminalID?,
        reassignedTerminalID: TerminalID
    ) -> Bool {
        guard selectedWorktreePath == sourceWorktreePath else { return false }
        guard sourceFocusedTerminalID == reassignedTerminalID else { return false }
        return true
    }
}
