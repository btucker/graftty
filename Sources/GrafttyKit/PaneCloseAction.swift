import Foundation

/// What Graftty should do when libghostty's `close_surface_cb` fires for
/// a pane — i.e., the PTY child (the `zmx attach` process) has exited.
public enum PaneCloseAction: Equatable, Sendable {
    /// Remove the pane from its worktree's split tree and free the surface
    /// (TERM-5.3). This is the only outcome today — see below for why.
    case closePane
}

/// Pure decision function for handling an unsolicited `close_surface_cb`.
///
/// Historical context: commit `0a553d1` added a "restart surface in place"
/// branch (ZMX-7.2) intended to keep panes visible when their zmx daemon
/// was killed externally. The detection signal it used —
/// `isSessionMissing && !grafttyInitiated` — cannot distinguish an
/// externally-killed daemon from the common case where the user typed
/// `exit` (which also ends the daemon). Shell-driven exit never flows
/// through `killZmxSession`, so `grafttyInitiated` reads as false in
/// both scenarios. The restart path therefore turned `exit` into "pane
/// stays with a restart banner," regressing TERM-5.3.
///
/// Until a zmx-side signal distinguishes clean shell exit from external
/// daemon kill, the policy is unconditional close. This function is the
/// seam where that future logic would land; keeping it here (and tested)
/// guards against a reviewer-missed reintroduction of the branch.
public func paneCloseAction() -> PaneCloseAction {
    .closePane
}
