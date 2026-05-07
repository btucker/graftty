import Foundation

public enum WorktreeRowIcon {
    /// SF Symbol name for the leading icon in a worktree's sidebar row.
    /// Swaps to `arrow.triangle.pull` (the universal PR/MR glyph) once a
    /// PR is associated with the worktree, so the user can see at a
    /// glance which worktrees have outstanding work upstream.
    public static func symbolName(isMainCheckout: Bool, hasPR: Bool) -> String {
        if hasPR { return "arrow.triangle.pull" }
        return isMainCheckout ? "house" : "arrow.triangle.branch"
    }
}
