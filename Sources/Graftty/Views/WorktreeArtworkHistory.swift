import Foundation
import GrafttyKit

/// Reads only the conversation registered to a worktree's first pane.
/// Call from a background executor because presence and conversation files are on disk.
struct WorktreeArtworkHistory: Sendable {
    // Codex includes base instructions in its first metadata line. Keep the
    // read bounded while allowing those records to exceed a small JSON header.
    private static let headerByteLimit = 1_024 * 1_024
    private static let tailByteLimit = 1_024 * 1_024
    private static let characterLimit = 4_000

    static func context(worktreePath: String, paneSessionName: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = environment["CODEX_HOME"].flatMap(directoryURL)
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].flatMap(directoryURL)
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        let records = (try? TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot()).listAll()) ?? []
        return context(worktreePath: worktreePath, paneSessionName: paneSessionName, records: records,
                       codexSessions: codexHome.appendingPathComponent("sessions", isDirectory: true),
                       claudeProjects: claudeHome.appendingPathComponent("projects", isDirectory: true))
    }

    static func context(worktreePath: String, paneSessionName: String, records: [TeamPresenceRecord],
                        codexSessions: URL, claudeProjects: URL) -> String? {
        guard !paneSessionName.isEmpty,
              let record = records.filter({
                  $0.worktree == worktreePath && $0.paneSessionName == paneSessionName
                      && $0.isSubagent != true && $0.runtimeSessionID != nil
              }).max(by: { $0.registeredAt < $1.registeredAt }),
              let sessionID = record.runtimeSessionID, validSessionID(sessionID),
              let file = conversationFile(sessionID: sessionID, runtime: record.runtime,
                                          root: record.runtime == .codex ? codexSessions : claudeProjects),
              let chunks = try? readChunks(file) else { return nil }

        let header = entries(chunks.header)
        let recent = entries(chunks.tail)
        switch record.runtime {
        case .codex:
            guard header.contains(where: { entry in
                guard entry["type"] as? String == "session_meta",
                      let payload = entry["payload"] as? [String: Any] else { return false }
                return payload["id"] as? String == sessionID && payload["cwd"] as? String == worktreePath
            }) else { return nil }
            return codexContext(recent) ?? codexContext(header)
        case .claude:
            guard (header + recent).contains(where: {
                $0["sessionId"] as? String == sessionID && $0["cwd"] as? String == worktreePath
            }) else { return nil }
            return claudeContext(recent, sessionID: sessionID, worktreePath: worktreePath)
                ?? claudeContext(header, sessionID: sessionID, worktreePath: worktreePath)
        }
    }

    // Long autonomous turns can push every genuine user prompt out of the
    // bounded tail. Reuse the already-read opening chunk in that case, applying
    // the same filters and output cap without scanning the full conversation.
    private static func codexContext(_ records: [[String: Any]]) -> String? {
        let primary = records.compactMap { entry -> String? in
            guard entry["type"] as? String == "response_item",
                  let payload = entry["payload"] as? [String: Any],
                  payload["type"] as? String == "message", payload["role"] as? String == "user" else { return nil }
            return AgentHookPrompt.userText(textContent(payload["content"], blockType: "input_text"))
        }
        // Modern rollouts record both forms. Prefer the message stream so each
        // prompt appears once; older rollouts can contain only user_message events.
        if !primary.isEmpty { return boundedContext(primary) }
        return boundedContext(records.compactMap { entry in
            guard entry["type"] as? String == "event_msg",
                  let payload = entry["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message" else { return nil }
            return AgentHookPrompt.userText(payload["message"] as? String)
        })
    }

    private static func claudeContext(_ records: [[String: Any]], sessionID: String, worktreePath: String) -> String? {
        boundedContext(records.compactMap { entry in
            guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
                  entry["isSidechain"] as? Bool != true,
                  entry["sessionId"] as? String == sessionID,
                  entry["cwd"] as? String == worktreePath,
                  let message = entry["message"] as? [String: Any],
                  message["role"] as? String == "user" else { return nil }
            if let blocks = message["content"] as? [[String: Any]],
               blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            return AgentHookPrompt.userText(textContent(message["content"], blockType: "text"))
        })
    }

    private static func directoryURL(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func conversationFile(sessionID: String, runtime: TeamHookRuntime, root: URL) -> URL? {
        // Graftty's managed CODEX_HOME links sessions back to the user's Codex home.
        // Directory enumeration does not descend through a symlink used as its root.
        guard let enumerator = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { return nil }
        // Inspect names only. Never load unrelated conversations while searching.
        for case let file as URL in enumerator.prefix(10_000) {
            let name = file.lastPathComponent
            switch runtime {
            case .codex:
                if name.hasPrefix("rollout-"), name.hasSuffix("-\(sessionID).jsonl") { return file }
            case .claude:
                if name == "\(sessionID).jsonl", !file.pathComponents.contains("subagents") { return file }
            }
        }
        return nil
    }

    private static func readChunks(_ url: URL) throws -> (header: Data, tail: Data) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: headerByteLimit) ?? Data()
        let offset = size > tailByteLimit ? size - UInt64(tailByteLimit) : 0
        try handle.seek(toOffset: offset)
        var tail = try handle.read(upToCount: tailByteLimit) ?? Data()
        if offset > 0 {
            // The tail may start partway through a large tool result or message.
            if let newline = tail.firstIndex(of: 10) { tail = Data(tail.suffix(from: tail.index(after: newline))) }
            else { tail = Data() }
        }
        return (header, tail)
    }

    private static func entries(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }

    private static func textContent(_ content: Any?, blockType: String) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return blocks.compactMap { block in
            block["type"] as? String == blockType ? block["text"] as? String : nil
        }.joined(separator: "\n")
    }

    private static func boundedContext(_ messages: [String]) -> String? {
        var selected: [String] = []
        var remaining = characterLimit
        for message in messages.suffix(5).reversed() {
            let separatorCount = selected.isEmpty ? 0 : 2
            guard remaining > separatorCount else { break }
            let excerpt = String(message.prefix(remaining - separatorCount))
            selected.append(excerpt)
            remaining -= excerpt.count + separatorCount
        }
        return selected.isEmpty ? nil : selected.reversed().joined(separator: "\n\n")
    }
}
