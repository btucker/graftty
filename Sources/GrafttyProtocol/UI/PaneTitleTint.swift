/// Presentation rule shared by both pane-row render surfaces (the Mac
/// sidebar and the iPad/web list). Centralized in `GrafttyProtocol` — the
/// only module both surfaces depend on — so the "a ping supersedes the
/// busy tint" precedence can't drift between platforms. macOS `swift test`
/// does not compile the iPad view, so a rule duplicated in both views
/// could ship false-green.
public enum PaneTitleTint {
    /// @spec AGENT-2.1
    /// A live attention capsule is rendered in preference to the derived
    /// busy state: the green "working" tint applies only when the pane has
    /// no active capsule. The capsule (needs-input notify pings, or the
    /// transient NOTIF-2.x ✓/! command-finished markers) owns the row's
    /// secondary surface for its brief lifetime, so the title defers to its
    /// normal color while one is showing rather than competing with it.
    ///
    /// `hasAttentionCapsule` is each surface's *resolved* notion of an
    /// active capsule — the iPad folds in IPAD-1.14 worktree-scoped
    /// inheritance, the Mac uses the pane-scoped ping directly.
    public static func showsBusyTint(isBusy: Bool, hasAttentionCapsule: Bool) -> Bool {
        isBusy && !hasAttentionCapsule
    }
}
