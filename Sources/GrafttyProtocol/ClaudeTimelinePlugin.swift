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
        guard let match = Self.slashCommand.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let name = Range(match.range(at: 1), in: text), let args = Range(match.range(at: 2), in: text) else { return nil }
        let command = [String(text[name]), String(text[args])].filter { !$0.isEmpty }.joined(separator: " ")
        return .init(source: .user, presentation: .init(kind: .command, items: [.init(value: command)]))
    }

    private static let slashCommand = try! NSRegularExpression(pattern:
        #"\A\s*<command-name>([^<]+)</command-name>\s*<command-message>[^<]*</command-message>\s*<command-args>([^<]*)</command-args>\s*\z"#)

    public func transcriptInput(from record: [String: Any], state: inout HarnessTimelineTranscriptState) -> WorktreePromptContent.Part? {
        guard record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return nil }
        if record["type"] as? String == "assistant", message["role"] as? String == "assistant" {
            for block in blocks where block["type"] as? String == "tool_use" && block["name"] as? String == "AskUserQuestion" {
                guard let id = block["id"] as? String, let input = block["input"] as? [String: Any],
                      let questions = input["questions"] as? [[String: Any]] else { continue }
                state.remember(questions.enumerated().compactMap { index, question in
                    guard let text = question["question"] as? String else { return nil }
                    return .init(id: String(index), text: text)
                }, callID: id)
            }
            return nil
        }
        guard record["type"] as? String == "user", message["role"] as? String == "user" else { return nil }
        var matchesQuestionCall = false
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String,
                  state.pendingQuestions.removeValue(forKey: id) != nil else { continue }
            if block["is_error"] as? Bool != true { matchesQuestionCall = true }
        }
        guard matchesQuestionCall,
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
