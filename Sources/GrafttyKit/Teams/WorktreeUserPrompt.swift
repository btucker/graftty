import Foundation

/// Provider prompt hooks also fire for Graftty's generated turns.
public enum WorktreeUserPrompt {
    public static func text(from payload: [String: Any]) -> String? {
        guard let prompt = payload["prompt"] as? String else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != WorktreeAgentLaunchCommand.bootstrapPrompt else { return nil }
        for envelope in ["graftty-peer-message", "graftty-system-message", "graftty-forge-message"] {
            if trimmed.hasPrefix("<\(envelope)>") || trimmed.hasPrefix("<\(envelope) ") {
                return nil
            }
        }
        return prompt
    }
}
