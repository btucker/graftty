import Foundation

public enum WorktreeRowIcon {
    /// SF Symbol name for the leading icon in a worktree's sidebar row.
    ///
    /// Main checkouts always show `house` — it's the only persistent
    /// visual indicator that the row is the repo's home base, and
    /// flipping it to a PR glyph would erase that cue (the PR/MR reference
    /// badge text on the same row already conveys PR-ness). For
    /// linked worktrees, `arrow.triangle.pull` (the universal PR/MR
    /// glyph) appears once a PR is associated, otherwise
    /// `arrow.triangle.branch`.
    public static func symbolName(isMainCheckout: Bool, hasPR: Bool) -> String {
        if isMainCheckout { return "house" }
        if hasPR { return "arrow.triangle.pull" }
        return "arrow.triangle.branch"
    }
}
