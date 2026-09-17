import Foundation

/// Extract only the provider's submitted user text, never tool arguments.
public enum AgentHookPrompt {
    public static func text(event: TeamHookEvent, payload: [String: Any]) -> String? {
        guard event == .userPromptSubmit,
              !AgentStopHookFilter.isSubagentStop(stdinJSON: payload),
              let prompt = userText(payload["prompt"] as? String) else { return nil }
        return bounded(prompt)
    }

    /// Apply the same injected-context exclusions to live hooks and saved history.
    /// Clean before bounding so a long message cannot hide its provenance tag.
    public static func userText(_ input: String?) -> String? {
        guard var text = input?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let injectedPrefixes = ["# AGENTS.md instructions", "<INSTRUCTIONS>", "<user_instructions>",
                                "[Request interrupted by user", "<local-command", "<command-name>"]
        guard !injectedPrefixes.contains(where: { text.hasPrefix($0) }),
              !["<graftty-peer-message", "<graftty-system-message", "<graftty-forge-message"].contains(where: { text.contains($0) }) else {
            return nil
        }
        for tag in ["environment_context", "system-reminder", "turn_aborted"] {
            text = text.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: "", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func bounded(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(4000))
    }
}
