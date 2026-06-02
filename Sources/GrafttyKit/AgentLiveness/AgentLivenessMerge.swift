import Foundation

/// Derives a pane's busy state from claude liveness, host-side. A live
/// `notify` ping is rendered as the red attention capsule (callers pass it
/// straight through to the view); busy is surfaced as a green title tint,
/// not a capsule — the title already animates, so a busy pane needs no
/// separate pill. The ping-vs-busy *render precedence* lives in
/// `GrafttyProtocol.PaneTitleTint` because both render surfaces share it;
/// this enum only computes busy from liveness, which only the host does.
public enum AgentLivenessMerge {
    /// AGENT-2.2: true when the pane's claude session is busy. Purely
    /// liveness-derived; `PaneTitleTint.showsBusyTint` decides whether a
    /// concurrent ping suppresses the tint.
    public static func isPaneBusy(
        sessionName: String?,
        liveness: [String: AgentLiveness]
    ) -> Bool {
        guard let sessionName else { return false }
        return liveness[sessionName] == .busy
    }
}
