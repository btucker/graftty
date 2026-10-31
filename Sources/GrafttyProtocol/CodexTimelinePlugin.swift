import Foundation

public struct CodexTimelinePlugin: HarnessTimelinePlugin {
    public let runtime = "codex"
    public let envelopeNames: Set<String> = [
        "send_user_message_question_reply", "user_shell_command", "turn_aborted", "user_action",
        "realtime_delegation", "external_codex_apps_open_page", "external_codex_apps_writing_block_edits",
        "hook_prompt", "guardian_tool_descriptions", "environment_context", "subagent_notification",
        "codex_internal_context", "recommended_plugins", "skill", "user_instructions",
        // Older saved mixed prompts also carry these hook envelopes.
        "system-reminder", "task-notification"
    ]
    public init() {}

    public func transcriptInput(from record: [String: Any], state: inout HarnessTimelineTranscriptState) -> WorktreePromptContent.Part? {
        guard record["type"] as? String == "response_item",
              let payload = record["payload"] as? [String: Any],
              let callID = payload["call_id"] as? String else { return nil }
        if payload["type"] as? String == "function_call",
           ["request_user_input", "functions.request_user_input"].contains(payload["name"] as? String ?? ""),
           let arguments = payload["arguments"] as? String,
           let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let questions = object["questions"] as? [[String: Any]] {
            state.remember(questions.compactMap {
                guard let id = $0["id"] as? String, let text = $0["question"] as? String else { return nil }
                return .init(id: id, text: text)
            }, callID: callID)
            return nil
        }
        guard payload["type"] as? String == "function_call_output",
              let questions = state.pendingQuestions.removeValue(forKey: callID),
              let output = payload["output"] as? String, let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: [String: Any]] else { return nil }
        let items = questions.compactMap { question -> HarnessTimelinePresentation.Item? in
            guard let values = answers[question.id]?["answers"] as? [String] else { return nil }
            return .init(label: question.text, value: values.joined(separator: "\n"))
        }
        guard !items.isEmpty else { return nil }
        return .init(source: .user, presentation: .init(kind: .questionReply, items: items))
    }

    public func parseEnvelope(name: String, header: String, body: String) -> WorktreePromptContent.Part? {
        switch name {
        case "subagent_notification":
            guard let data = body.data(using: .utf8),
                  let notification = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sender = notification["agent_id"] as? String ?? notification["agent_path"] as? String,
                  let status = notification["status"] as? [String: Any],
                  let report = status["completed"] as? String ?? status["errored"] as? String else { return nil }
            // Native agent paths are task names, not navigable worktree paths.
            let label = sender.hasPrefix("/") ? "Subagent \(sender)" : sender
            return .init(source: .agent(label), text: report)
        case "skill":
            guard let name = HarnessEnvelope.value("name", in: body), !name.isEmpty,
                  HarnessEnvelope.value("path", in: body) != nil else { return nil }
            return .init(source: .generated, presentation: .init(kind: .context, items: [.init(label: "Skill loaded", value: name)]))
        case "user_instructions":
            return .init(source: .generated, presentation: .init(kind: .context, items: [
                .init(value: "Repository instructions supplied."), .init(label: "Instructions", value: body)]))
        case "send_user_message_question_reply":
            guard let data = body.data(using: .utf8),
                  let replies = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !replies.isEmpty else { return nil }
            var items: [HarnessTimelinePresentation.Item] = []
            for reply in replies {
                guard let question = reply["question"] as? String, !question.isEmpty,
                      let answer = reply["answer"] as? String else { return nil }
                items.append(.init(label: question, value: answer))
            }
            return .init(source: .user, presentation: .init(kind: .questionReply, items: items))
        case "user_shell_command":
            guard let command = HarnessEnvelope.value("command", in: body), !command.isEmpty else { return nil }
            var items: [HarnessTimelinePresentation.Item] = [.init(value: command)]
            if let output = HarnessEnvelope.value("result", in: body), !output.isEmpty {
                items.append(.init(label: "Output", value: output))
            }
            return .init(source: .user, presentation: .init(kind: .command, items: items))
        case "turn_aborted":
            return .init(source: .generated, presentation: .init(kind: .interruption, items: [.init(value: "Turn interrupted.")]))
        case "user_action":
            guard HarnessEnvelope.value("action", in: body) == "review",
                  let result = HarnessEnvelope.value("results", in: body) else { return nil }
            return .init(source: .generated, presentation: .init(kind: .review, items: [.init(value: result)]))
        case "realtime_delegation":
            guard let input = HarnessEnvelope.value("input", in: body), !input.isEmpty else { return nil }
            return .init(source: .user, presentation: .init(kind: .voiceInput, items: [.init(value: input)]))
        case "external_codex_apps_open_page":
            guard let data = body.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = page["page_id"] else { return nil }
            return .init(source: .generated, presentation: .init(kind: .context, items: [.init(value: id is NSNull ? "No page selected." : "Page selected.")]))
        case "external_codex_apps_writing_block_edits":
            return .init(source: .generated, presentation: .init(kind: .context, items: [
                .init(value: "Document edits received."), .init(label: "Details", value: body.trimmingCharacters(in: .whitespacesAndNewlines))]))
        case "hook_prompt", "guardian_tool_descriptions", "environment_context", "codex_internal_context",
             "recommended_plugins", "system-reminder", "task-notification": return .hidden
        default: return nil
        }
    }
}
