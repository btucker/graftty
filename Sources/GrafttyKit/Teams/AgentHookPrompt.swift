import Foundation

/// Extract only the provider's submitted user text, never tool arguments.
public enum AgentHookPrompt {
    public static func text(event: TeamHookEvent, payload: [String: Any]) -> String? {
        guard event == .userPromptSubmit, let prompt = payload["prompt"] as? String else { return nil }
        return bounded(prompt)
    }

    public static func bounded(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(4000))
    }
}
