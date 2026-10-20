import Foundation
import GrafttyProtocol

/// Provider prompt hooks also fire for Graftty's generated turns.
public enum WorktreeUserPrompt {
    public static func text(from payload: [String: Any]) -> String? {
        guard let prompt = payload["prompt"] as? String else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != WorktreeAgentLaunchCommand.bootstrapPrompt else { return nil }
        guard !WorktreePromptContent.parts(in: prompt).isEmpty else { return nil }
        return prompt
    }
}
