import Foundation

/// Splits a pane's two independent signals. `effectivePaneText` surfaces
/// only a live `notify` ping (rendered as the red attention capsule).
/// `isPaneBusy` derives "claude is running" from liveness (rendered as a
/// green title tint, not a capsule) — the title already animates, so a
/// busy pane needs no separate pill. The two are rendered in different
/// places (capsule beside the title vs. tint *of* the title), so they do
/// not need to arbitrate each other here.
public enum AgentLivenessMerge {
    /// AGENT-2.1: the live notify ping, or nil. Busy/idle no longer feed
    /// this — busy is surfaced via `isPaneBusy` and a title tint instead.
    public static func effectivePaneText(
        paneAttentionText: String?,
        sessionName: String?,
        liveness: [String: AgentLiveness]
    ) -> String? {
        paneAttentionText
    }

    /// AGENT-2.2: true when the pane's claude session is busy. Purely
    /// liveness-derived; the caller decides to suppress the busy tint when
    /// a ping is also present (a needs-input ping supersedes "working").
    public static func isPaneBusy(
        sessionName: String?,
        liveness: [String: AgentLiveness]
    ) -> Bool {
        guard let sessionName else { return false }
        return liveness[sessionName] == .busy
    }
}
