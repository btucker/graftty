import Foundation

public struct ClaudeTimelinePlugin: HarnessTimelinePlugin {
    public let runtime = "claude"
    public let envelopeNames: Set<String> = [
        "system-reminder", "task-notification", "local-command-caveat", "forked-skill-launch",
        "bash-input", "bash-stdout", "bash-stderr", "local-command-stdout", "local-command-stderr",
        "cross-session-message", "agent-message", "environment_context"
    ]
    public init() {}

    public func parseEnvelope(name: String, header: String, body: String) -> WorktreePromptContent.Part? {
        switch name {
        case "cross-session-message", "agent-message":
            return .init(source: .agent(WorktreePromptContent.attribute("from-name", in: header)
                ?? WorktreePromptContent.attribute("from", in: header)), text: body)
        case "system-reminder", "task-notification", "local-command-caveat", "forked-skill-launch", "environment_context": return .hidden
        case "bash-input":
            return .init(source: .user, presentation: .init(kind: .command, items: [.init(value: body.trimmingCharacters(in: .whitespacesAndNewlines))]))
        case "bash-stdout", "bash-stderr", "local-command-stdout", "local-command-stderr":
            return .init(source: .generated, presentation: .init(kind: .commandOutput, items: [.init(value: body.trimmingCharacters(in: .whitespacesAndNewlines))]))
        default: return nil
        }
    }

    public func unwrapsNestedEnvelopes(named name: String) -> Bool {
        name == "cross-session-message" || name == "agent-message"
    }

    public func skipsLine(_ line: String, following: Substring) -> Bool {
        line == "Another Claude session sent a message:"
            && following.drop(while: { $0.isWhitespace }).hasPrefix("<cross-session-message")
    }

    public func parseText(_ text: String) -> WorktreePromptContent.Part? {
        if ["[Request interrupted by user]", "[Request interrupted by user for tool use]"].contains(text) {
            return .init(source: .generated, presentation: .init(kind: .interruption, items: [.init(value: "Turn interrupted.")]))
        }
        if text.hasPrefix("This session is being continued from a previous conversation that ran out of context."),
           text.contains("\nSummary:") { return .hidden }
        // Slash-command metadata forms one message. Require the complete shape,
        // so a pasted fragment or an unfamiliar command format stays readable.
        let pattern = #"\A\s*<command-name>([^<]+)</command-name>\s*<command-message>[^<]*</command-message>\s*<command-args>([^<]*)</command-args>\s*\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let name = Range(match.range(at: 1), in: text), let args = Range(match.range(at: 2), in: text) else { return nil }
        let command = [String(text[name]), String(text[args])].filter { !$0.isEmpty }.joined(separator: " ")
        return .init(source: .user, presentation: .init(kind: .command, items: [.init(value: command)]))
    }

    public func transcriptInput(from record: [String: Any], state: inout HarnessTimelineTranscriptState) -> WorktreePromptContent.Part? {
        guard record["type"] as? String == "user", record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any], message["role"] as? String == "user",
              let blocks = message["content"] as? [[String: Any]],
              blocks.contains(where: { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool != true }),
              let result = record["toolUseResult"] as? [String: Any],
              let questions = result["questions"] as? [[String: Any]], !questions.isEmpty,
              let answers = result["answers"] as? [String: String] else { return nil }
        let items = questions.compactMap { question -> HarnessTimelinePresentation.Item? in
            guard let text = question["question"] as? String, let answer = answers[text] else { return nil }
            return .init(label: text, value: answer)
        }
        guard !items.isEmpty else { return nil }
        return .init(source: .user, presentation: .init(kind: .questionReply, items: items))
    }
}
