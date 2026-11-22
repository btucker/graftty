import Foundation
import GrafttyProtocol

/// Translates Codex app-server messages for one thread into chat events.
/// Shapes follow `codex app-server generate-ts` for codex-cli 0.171.0.
enum CodexChatDecoder {
    struct History: Equatable {
        var items: [AgentChatItem]
        var turnState: AgentChatTurnState
        var activeTurnID: String?
    }

    static func events(notification method: String, params: [String: Any], threadID: String) -> [AgentChatEvent] {
        guard params["threadId"] as? String == threadID else { return [] }
        let turnID = params["turnId"] as? String
        switch method {
        case "item/started", "item/completed":
            guard let raw = params["item"] as? [String: Any],
                  let item = item(raw, turnID: turnID, turnComplete: method == "item/completed")
            else { return [] }
            return [.item(item)]
        case "item/agentMessage/delta":
            return delta(params, turnID: turnID, kind: .agent)
        case "item/reasoning/summaryTextDelta":
            return delta(params, turnID: turnID, kind: .reasoning)
        case "thread/status/changed":
            guard let status = params["status"] as? [String: Any] else { return [] }
            return [.turnState(turnState(status))]
        case "serverRequest/resolved":
            guard let id = requestID(params["requestId"]) else { return [] }
            return [.requestResolved(id: id)]
        case "thread/closed":
            return [.ended(reason: "The agent closed this conversation.")]
        default:
            return []
        }
    }

    static func request(
        id: String, method: String, params: [String: Any], threadID: String
    ) -> AgentChatPendingRequest? {
        guard params["threadId"] as? String == threadID else { return nil }
        let reason = params["reason"] as? String
        switch method {
        case "item/commandExecution/requestApproval":
            return AgentChatPendingRequest(
                id: id, kind: .commandApproval,
                summary: params["command"] as? String ?? "Run a command",
                detail: reason, canAnswerInChat: true
            )
        case "item/fileChange/requestApproval":
            return AgentChatPendingRequest(
                id: id, kind: .fileChangeApproval, summary: "Apply file changes",
                detail: reason, canAnswerInChat: true
            )
        default:
            return AgentChatPendingRequest(
                id: id, kind: .other, summary: "The agent is waiting for an answer",
                detail: reason, canAnswerInChat: false
            )
        }
    }

    /// Reads the `thread` object returned by `thread/read` or `thread/resume`.
    static func history(threadResult: [String: Any]) -> History? {
        guard let thread = threadResult["thread"] as? [String: Any] else { return nil }
        var history = History(items: [], turnState: .idle, activeTurnID: nil)
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            let turnID = turn["id"] as? String
            let inProgress = turn["status"] as? String == "inProgress"
            if inProgress { history.activeTurnID = turnID }
            let rawItems = turn["items"] as? [[String: Any]] ?? []
            for (index, raw) in rawItems.enumerated() {
                // Only the last item of a running turn can still be streaming.
                let settled = !inProgress || index < rawItems.count - 1
                if let item = item(raw, turnID: turnID, turnComplete: settled) {
                    history.items.append(item)
                }
            }
        }
        if let status = thread["status"] as? [String: Any] {
            history.turnState = turnState(status)
        }
        return history
    }

    struct Skill: Equatable {
        let command: AgentChatCommand
        let path: String?
    }

    /// Codex invokes a skill by a `$name` mention in the prompt.
    static func skills(skillsResult: [String: Any]) -> [Skill] {
        var seen = Set<String>()
        var skills: [Skill] = []
        for entry in skillsResult["data"] as? [[String: Any]] ?? [] {
            for skill in entry["skills"] as? [[String: Any]] ?? [] {
                guard skill["enabled"] as? Bool != false,
                      let name = skill["name"] as? String, seen.insert(name).inserted else { continue }
                let description = skill["shortDescription"] as? String ?? skill["description"] as? String ?? ""
                skills.append(Skill(
                    command: AgentChatCommand(name: name, description: description, invocation: "$\(name)"),
                    path: skill["path"] as? String
                ))
            }
        }
        return skills
    }

    /// The prompt as Codex input: its text, plus one skill item for each
    /// known skill the text mentions.
    static func input(text: String, skills: [Skill]) -> [[String: Any]] {
        var input: [[String: Any]] = [["type": "text", "text": text, "text_elements": [Any]()]]
        let words = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
        for skill in skills {
            guard let path = skill.path, words.contains(skill.command.invocation) else { continue }
            input.append(["type": "skill", "name": skill.command.name, "path": path])
        }
        return input
    }

    static func turnState(_ status: [String: Any]) -> AgentChatTurnState {
        guard status["type"] as? String == "active" else { return .idle }
        let flags = status["activeFlags"] as? [String] ?? []
        return flags.contains { $0.hasPrefix("waitingOn") } ? .waitingOnRequest : .active
    }

    /// JSON-RPC IDs are numbers or strings. Chat addresses them as strings.
    static func requestID(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? Int { return String(number) }
        return nil
    }

    private static func delta(_ params: [String: Any], turnID: String?, kind: AgentChatItem.Kind) -> [AgentChatEvent] {
        guard let itemID = params["itemId"] as? String, let delta = params["delta"] as? String else { return [] }
        return [.textDelta(itemID: itemID, turnID: turnID, kind: kind, delta: delta)]
    }

    private static func item(_ raw: [String: Any], turnID: String?, turnComplete: Bool) -> AgentChatItem? {
        guard let id = raw["id"] as? String, let type = raw["type"] as? String else { return nil }
        func make(
            _ kind: AgentChatItem.Kind, _ text: String, detail: String? = nil,
            submissionID: String? = nil, complete: Bool = turnComplete
        ) -> AgentChatItem {
            AgentChatItem(id: id, turnID: turnID, kind: kind, text: text, detail: detail,
                          submissionID: submissionID, isComplete: complete)
        }
        let running = raw["status"] as? String == "inProgress"
        switch type {
        case "userMessage":
            let parts = (raw["content"] as? [[String: Any]] ?? []).compactMap(userText)
            return make(.user, parts.joined(separator: "\n"), submissionID: raw["clientId"] as? String,
                        complete: true)
        case "agentMessage":
            return make(.agent, raw["text"] as? String ?? "")
        case "plan":
            return make(.agent, raw["text"] as? String ?? "")
        case "reasoning":
            let text = (raw["summary"] as? [String] ?? []).joined(separator: "\n\n")
            // Codex reports reasoning with no summary. Streamed summary text
            // creates the row when there is something to show.
            return text.isEmpty ? nil : make(.reasoning, text)
        case "commandExecution":
            return make(.command, raw["command"] as? String ?? "", detail: raw["aggregatedOutput"] as? String,
                        complete: turnComplete && !running)
        case "fileChange":
            let paths = (raw["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return make(.fileChange, paths.isEmpty ? "Changed files" : paths.joined(separator: "\n"),
                        complete: turnComplete && !running)
        case "mcpToolCall", "dynamicToolCall":
            let name = [raw["server"] as? String, raw["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            return make(.tool, name, complete: turnComplete && !running)
        case "webSearch":
            return make(.tool, "Web search: \(raw["query"] as? String ?? "")")
        case "enteredReviewMode":
            return make(.notice, "Review started")
        case "exitedReviewMode":
            return make(.notice, "Review finished")
        case "contextCompaction":
            return make(.notice, "Conversation compacted")
        default:
            return nil
        }
    }

    private static func userText(_ part: [String: Any]) -> String? {
        switch part["type"] as? String {
        case "text": return part["text"] as? String
        case "image", "localImage": return "[image]"
        case "skill", "mention": return (part["name"] as? String).map { "$\($0)" }
        default: return nil
        }
    }
}
