/// Presentation rule shared by both pane-row render surfaces (the Mac
/// sidebar and the iPad/web list). Centralized in `GrafttyProtocol` — the
/// only module both surfaces depend on — so the "a ping supersedes the
/// busy tint" precedence can't drift between platforms. macOS `swift test`
/// does not compile the iPad view, so a rule duplicated in both views
/// could ship false-green.
public enum PaneTitleTint {
    /// @spec AGENT-2.1
    /// A live attention ping is rendered in preference to the derived busy
    /// state: the green "working" tint applies only when the pane has no
    /// active attention capsule. A needs-input ping means claude is
    /// waiting (capsule beside the title), not working.
    ///
    /// `hasAttentionCapsule` is each surface's *resolved* notion of an
    /// active capsule — the iPad folds in IPAD-1.14 worktree-scoped
    /// inheritance, the Mac uses the pane-scoped ping directly.
    public static func showsBusyTint(isBusy: Bool, hasAttentionCapsule: Bool) -> Bool {
        isBusy && !hasAttentionCapsule
    }
}
