import Foundation

/// @spec AGENT-3.6: When a provider hook explicitly reports a surfaced permission request, user question, or plan-review prompt, the application shall create the corresponding needs-input attention for that agent.
public enum AgentHookAttentionReason: String, Codable, Sendable, Equatable {
    case permission
    case question
    case planReview = "plan_review"
}

public enum AgentHookAttentionClassifier {
    public static func reason(
        runtime: TeamHookRuntime,
        event: TeamHookEvent,
        stdinJSON: [String: Any]
    ) -> AgentHookAttentionReason? {
        if event == .permissionRequest || event == .preToolUse,
           let toolName = stdinJSON["tool_name"] as? String {
            switch normalizedToolName(toolName) {
            case "askuserquestion", "requestuserinput":
                return .question
            case "exitplanmode":
                return .planReview
            default:
                break
            }
        }

        // Codex emits PermissionRequest before Guardian or another approval
        // policy has decided whether the user is actually needed. Treating it
        // as authoritative recreates the false-positive alert this classifier
        // is meant to prevent. Claude's event represents a surfaced prompt.
        if event == .permissionRequest, runtime == .claude {
            return .permission
        }
        return nil
    }

    private static func normalizedToolName(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }
}

public enum AgentHookAttentionAction: Sendable, Equatable {
    case record(AgentHookAttentionReason)
    case clear
    case none
}

/// Converts provider hook semantics into one small, testable attention state
/// transition. A bare Stop is intentionally only a lifecycle signal.
public enum AgentHookAttentionTransition {
    public static func action(
        event: TeamHookEvent,
        reason: AgentHookAttentionReason?
    ) -> AgentHookAttentionAction {
        if let reason {
            return .record(reason)
        }
        switch event {
        case .sessionStart, .userPromptSubmit, .postToolUse, .postToolUseFailure:
            return .clear
        case .preToolUse, .permissionRequest, .stop:
            return .none
        }
    }
}

/// Stable ownership key for attention created by one provider session. The
/// native session ID is preferred because wrapper agent IDs can change across
/// launches; the wrapper ID is still safer than cross-agent target matching.
public enum AgentHookAttentionIdentity {
    public static func key(
        runtime: TeamHookRuntime,
        sessionID: String?,
        callerAgentID: String?
    ) -> String? {
        if let sessionID = normalized(sessionID) {
            return "\(runtime.rawValue):session:\(sessionID)"
        }
        if let callerAgentID = normalized(callerAgentID) {
            return "\(runtime.rawValue):agent:\(callerAgentID)"
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
