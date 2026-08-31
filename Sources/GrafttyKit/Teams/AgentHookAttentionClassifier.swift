import Foundation

/// @spec AGENT-3.6: When a provider hook explicitly reports a permission request, user question, or plan-review prompt, the application shall create the corresponding needs-input attention for that agent.
public enum AgentHookAttentionReason: String, Codable, Sendable, Equatable {
    case permission
    case question
    case planReview = "plan_review"
}

public enum AgentHookAttentionClassifier {
    public static func reason(
        event: TeamHookEvent,
        stdinJSON: [String: Any]
    ) -> AgentHookAttentionReason? {
        switch event {
        case .permissionRequest:
            return .permission
        case .preToolUse:
            guard let toolName = stdinJSON["tool_name"] as? String else {
                return nil
            }
            switch normalizedToolName(toolName) {
            case "askuserquestion", "requestuserinput":
                return .question
            case "exitplanmode":
                return .planReview
            default:
                return nil
            }
        case .sessionStart, .postToolUse, .stop:
            return nil
        }
    }

    private static func normalizedToolName(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }
}
