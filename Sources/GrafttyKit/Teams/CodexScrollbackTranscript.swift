import Foundation
import GrafttyProtocol

/// A read-only fallback for a local Codex pane whose lifecycle hooks missed messages.
public enum CodexScrollbackTranscript {
    public static func read(sessionID: String, worktree: String,
                            codexHome: URL = CodexHomeMirror.defaultSourceDirectory()) -> WorktreeTimeline? {
        guard let session = UUID(uuidString: sessionID), let files = FileManager.default.enumerator(
            at: codexHome.appendingPathComponent("sessions"), includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let suffix = "-\(session.uuidString.lowercased()).jsonl"
        for case let file as URL in files where file.lastPathComponent.lowercased().hasSuffix(suffix) {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let history = try? read(file, session: session, worktree: worktree) {
                return WorktreeTimeline(history: history, brief: nil)
            }
        }
        return nil
    }

    private static func read(_ url: URL, session: UUID, worktree: String) throws -> WorktreeHistory? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 64 * 1024), let newline = header.firstIndex(of: 10),
              let record = try JSONSerialization.jsonObject(with: header[..<newline]) as? [String: Any],
              record["type"] as? String == "session_meta", let meta = record["payload"] as? [String: Any],
              let id = meta["id"] as? String, UUID(uuidString: id) == session,
              let cwd = meta["cwd"] as? String, cwd.hasPrefix("/"),
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path ==
                URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path else { return nil }

        let end = try file.seekToEnd()
        let limit: UInt64 = 4 * 1024 * 1024
        let start = end > limit ? end - limit : 0
        try file.seek(toOffset: start > 0 ? start - 1 : 0)
        let atLineStart = start == 0 ? true : try file.read(upToCount: 1)?.first == 10
        guard let bytes = try file.read(upToCount: Int(end - start)), let last = bytes.lastIndex(of: 10) else { return nil }
        guard let first = atLineStart ? bytes.startIndex : bytes.firstIndex(of: 10).map({ $0 + 1 }),
              first <= last else { return nil }
        var history = WorktreeHistory()
        for line in bytes[first..<last].split(separator: 10) {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let offset = start + UInt64(line.startIndex)
            if let input = userInput(from: record, sessionID: id, offset: offset) { history.record(input) }
            if let response = AgentResponseCapture.response(from: record, runtime: .codex, sessionID: id, offset: offset) {
                history.record(response)
            }
        }
        return history
    }

    private static func userInput(from record: [String: Any], sessionID: String, offset: UInt64) -> WorktreeHistory.UserInput? {
        guard record["type"] as? String == "event_msg", let payload = record["payload"] as? [String: Any] else { return nil }
        let text: String
        let sourceID: String
        switch payload["type"] as? String {
        case "user_message":
            guard let message = payload["message"] as? String else { return nil }
            text = message
            sourceID = "row:\(offset)"
        case "item_completed":
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage",
                  let content = item["content"] as? [[String: Any]] else { return nil }
            text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            sourceID = item["id"] as? String ?? "row:\(offset)"
        default: return nil
        }
        guard !text.isEmpty, let date = AgentResponseCapture.recordDate(record),
              let id = AgentResponseCapture.inputID(runtime: .codex, sessionID: sessionID, sourceID: sourceID) else { return nil }
        return .init(id: id, text: text, at: date, runtime: "codex")
    }
}
