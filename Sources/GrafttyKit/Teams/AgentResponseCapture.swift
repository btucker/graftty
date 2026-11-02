import Foundation
import GrafttyProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Reads only newly appended transcript records. Provider hooks supply the exact
/// session path. Only visible replies and validated human question answers enter the timeline.
public struct AgentResponseCapture {
    private struct Cursor: Codable {
        var offset: UInt64 = 0
        var fileNumber: UInt64
        var discardingLine = false
        var lastResponse: WorktreeHistory.AgentResponse?
        var lastResponseWorktree: String?
        var inputState: HarnessTimelineTranscriptState?
    }

    public let handoff: AttentionFileHandoff

    public init(handoff: AttentionFileHandoff = AttentionFileHandoff()) { self.handoff = handoff }

    public func capture(payload: [String: Any], runtime: TeamHookRuntime, worktree: String, sessionID: String?,
                        turnCompleted: Bool = false) throws {
        guard !AgentStopHookFilter.isSubagentStop(stdinJSON: payload),
              let sessionID, !sessionID.isEmpty,
              let path = payload["transcript_path"] as? String, path.hasPrefix("/") else { return }
        let file = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        try handoff.ensureDirectory()
        let directory = handoff.rootDirectory.appendingPathComponent("transcript-cursors", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // A session can change directories; that must not replay its old replies
        // into the newly resolved worktree's history.
        let key = SHA256.hash(data: Data("\(runtime.rawValue)\0\(sessionID)\0\(path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let cursorURL = directory.appendingPathComponent(key + ".json")
        // Parallel tool completions can run hooks together. The next hook retries
        // an occupied cursor instead of delaying the agent behind a file lock.
        guard let lease = try? ExclusiveFileLock(url: cursorURL.appendingPathExtension("lock"), wait: false) else { return }
        defer { withExtendedLifetime(lease) {} }
        let saved = try? JSONDecoder().decode(Cursor.self, from: Data(contentsOf: cursorURL))
        let isInitialScan = saved == nil || saved?.fileNumber != number || (saved?.offset ?? 0) > size
        var cursor = saved ?? Cursor(fileNumber: number)
        if isInitialScan { cursor = Cursor(fileNumber: number) }
        guard cursor.offset < size else {
            if turnCompleted {
                try completeTurn(cursor: &cursor)
                try JSONEncoder().encode(cursor).write(to: cursorURL, options: .atomic)
            }
            return
        }
        // Backfill only the recent tail on first observation. Once established,
        // stream every unread record so large tool results cannot erase replies.
        let limit = 2 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        if isInitialScan, size - cursor.offset > UInt64(limit) {
            cursor.offset = size - UInt64(limit)
            try handle.seek(toOffset: cursor.offset - 1)
            cursor.discardingLine = try handle.read(upToCount: 1)?.first != 0x0A
        }
        try handle.seek(toOffset: cursor.offset)
        var pending = Data()
        var readOffset = cursor.offset
        var recordOffset = cursor.offset
        while readOffset < size {
            guard let chunk = try handle.read(upToCount: Int(min(65_536, size - readOffset))), !chunk.isEmpty else { break }
            readOffset += UInt64(chunk.count)
            var start = chunk.startIndex
            for newline in chunk.indices where chunk[newline] == 0x0A {
                if !cursor.discardingLine, pending.count + newline - start <= limit {
                    pending.append(contentsOf: chunk[start..<newline])
                    if let record = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] {
                        var inputState = cursor.inputState ?? HarnessTimelineTranscriptState()
                        if let input = Self.input(from: record, runtime: runtime, sessionID: sessionID,
                                                  offset: recordOffset, state: &inputState) {
                            try handoff.input(input, worktree: worktree, runtime: runtime, sessionID: sessionID)
                        }
                        cursor.inputState = inputState
                        if let response = Self.response(from: record, runtime: runtime,
                                                         sessionID: sessionID, offset: recordOffset) {
                            try handoff.response(response, worktree: worktree)
                            cursor.lastResponse = response
                            cursor.lastResponseWorktree = worktree
                        }
                    }
                }
                pending.removeAll(keepingCapacity: true)
                cursor.discardingLine = false
                start = newline + 1
                recordOffset = readOffset - UInt64(chunk.endIndex - start)
            }
            if !cursor.discardingLine {
                if pending.count + chunk.endIndex - start <= limit {
                    pending.append(contentsOf: chunk[start...])
                } else {
                    pending.removeAll(keepingCapacity: true)
                    cursor.discardingLine = true
                }
            }
            cursor.offset = cursor.discardingLine ? readOffset : recordOffset
        }
        if turnCompleted { try completeTurn(cursor: &cursor) }
        try JSONEncoder().encode(cursor).write(to: cursorURL, options: .atomic)
    }

    static func input(from data: Data, runtime: TeamHookRuntime, sessionID: String, offset: UInt64 = 0,
                      state: inout HarnessTimelineTranscriptState) -> WorktreeHistory.UserInput? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return input(from: record, runtime: runtime, sessionID: sessionID, offset: offset, state: &state)
    }

    private static func input(from record: [String: Any], runtime: TeamHookRuntime, sessionID: String, offset: UInt64,
                              state: inout HarnessTimelineTranscriptState) -> WorktreeHistory.UserInput? {
        guard record["isSidechain"] as? Bool != true else { return nil }
        if let recordedSession = record["sessionId"] as? String ?? record["session_id"] as? String,
           recordedSession != sessionID { return nil }
        guard let plugin = HarnessTimelinePlugins.matching(runtime.rawValue).first,
              let part = plugin.transcriptInput(from: record, state: &state),
              let date = recordDate(record) else { return nil }
        let payload = record["payload"] as? [String: Any]
        let sourceID = record["uuid"] as? String ?? payload?["call_id"] as? String ?? "row:\(offset)"
        let digest = SHA256.hash(data: Data("input\0\(runtime.rawValue)\0\(sessionID)\0\(sourceID)".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(digest[digest.index(digest.startIndex, offsetBy: range.lowerBound)..<digest.index(digest.startIndex, offsetBy: range.upperBound)])
        }
        guard let id = UUID(uuidString: groups.joined(separator: "-")) else { return nil }
        return .init(id: id, text: part.text, at: date, runtime: runtime.rawValue, parts: [part])
    }

    private static func recordDate(_ record: [String: Any]) -> Date? {
        guard let timestamp = record["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }

    /// Claude's final text can already have been drained at the previous tool boundary.
    private func completeTurn(cursor: inout Cursor) throws {
        guard var response = cursor.lastResponse, let destination = cursor.lastResponseWorktree,
              response.isFinal != true else { return }
        response.isFinal = true
        try handoff.response(response, worktree: destination)
        cursor.lastResponse = response
    }

    static func response(from data: Data, runtime: TeamHookRuntime, sessionID: String,
                         offset: UInt64 = 0) -> WorktreeHistory.AgentResponse? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return response(from: record, runtime: runtime, sessionID: sessionID, offset: offset)
    }

    private static func response(from record: [String: Any], runtime: TeamHookRuntime, sessionID: String,
                                 offset: UInt64) -> WorktreeHistory.AgentResponse? {
        guard record["isSidechain"] as? Bool != true else { return nil }
        let message: [String: Any]
        let sourceID: String
        switch runtime {
        case .codex:
            guard record["type"] as? String == "response_item",
                  let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "message" else { return nil }
            let phase = payload["phase"] as? String ?? payload["channel"] as? String
            if let phase, !["commentary", "final", "final_answer"].contains(phase) { return nil }
            let metadata = record["metadata"] as? [String: Any]
            let retained = metadata?["retained_source"] as? [String: Any]
            guard retained?["complete"] as? Bool != false else { return nil }
            message = payload
            sourceID = payload["id"] as? String ?? "row:\(offset)"
        case .claude:
            guard record["type"] as? String == "assistant",
                  let payload = record["message"] as? [String: Any] else { return nil }
            if let recordedSession = record["sessionId"] as? String ?? record["session_id"] as? String,
               recordedSession != sessionID { return nil }
            message = payload
            // Claude may emit text and tool blocks under the same message id.
            sourceID = record["uuid"] as? String ?? payload["id"] as? String ?? "row:\(offset)"
        }
        guard message["role"] as? String == "assistant",
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard ["output_text", "text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var date = recordDate(record) else { return nil }
        if let metadata = message["internal_chat_message_metadata_passthrough"] as? [String: Any],
           let created = metadata["create_time"] as? Double, created.isFinite {
            date = Date(timeIntervalSince1970: created)
        }
        let key = SHA256.hash(data: Data("\(runtime.rawValue)\0\(sessionID)\0\(sourceID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let phase = message["phase"] as? String ?? message["channel"] as? String
        let isFinal = ["final", "final_answer"].contains(phase ?? "") || message["stop_reason"] as? String == "end_turn"
        return WorktreeHistory.AgentResponse(id: "response:\(key)", text: text, at: date, runtime: runtime.rawValue,
                                            sessionID: sessionID, isFinal: isFinal)
    }
}
