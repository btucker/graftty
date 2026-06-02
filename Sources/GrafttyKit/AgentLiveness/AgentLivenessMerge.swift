import Foundation

/// The single notify-wins merge used by both render surfaces (Mac sidebar
/// and the iPad/web wire model). A live `notify` ping always wins; derived
/// busy/idle only fills the gap. Idle shows nothing to avoid visual noise.
public enum AgentLivenessMerge {
    public static let busyText = "working…"

    public static func effectivePaneText(
        paneAttentionText: String?,
        sessionName: String?,
        liveness: [String: AgentLiveness]
    ) -> String? {
        if let paneAttentionText { return paneAttentionText }   // AGENT-2.1
        guard let sessionName, liveness[sessionName] == .busy else { return nil }
        return busyText                                          // AGENT-2.2
    }
}
