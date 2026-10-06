import Foundation

/// Provider evidence for automatic suspension, independent of Attention liveness.
/// `unknown` must keep the provider awake. `idle` requires confirmed visibility
/// of all work that can continue or wake the session; current adapters cannot
/// provide that guarantee.
public enum ProviderSleepActivity: String, Codable, Sendable {
    case unknown
    case busy
    case idle

    /// Claude's Stop registries describe in-flight tasks and scheduled wakeups.
    /// Missing registries mean the registry was unreachable on supported versions.
    /// Empty registries still cannot confirm final idle: other Stop hooks can
    /// request continuation after this hook, and SubagentStop concerns a child.
    /// https://code.claude.com/docs/en/hooks#stop
    public static func claudeHook(payload: [String: Any], event: String) -> ProviderSleepActivity {
        if payload["stop_hook_active"] as? Bool == true { return .unknown }
        if let tasks = payload["background_tasks"] as? [Any], !tasks.isEmpty { return .busy }
        if let crons = payload["session_crons"] as? [Any], !crons.isEmpty { return .busy }
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest":
            return .busy
        default:
            return .unknown
        }
    }
}
