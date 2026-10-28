import Foundation
import GrafttyProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Reads only newly appended transcript records. Provider hooks supply the exact
/// session path; no unrelated sessions or tool output enter the timeline.
public struct AgentResponseCapture {
    private struct Cursor: Codable {
        var offset: UInt64 = 0
        var fileNumber: UInt64
        var discardingLine = false
    }

    public let handoff: AttentionFileHandoff

    public init(handoff: AttentionFileHandoff = AttentionFileHandoff()) { self.handoff = handoff }

    public func capture(payload: [String: Any], runtime: TeamHookRuntime, worktree: String, sessionID: String?) throws {
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
        let key = SHA256.hash(data: Data("\(worktree)\0\(runtime.rawValue)\0\(sessionID)\0\(path)".utf8))
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
        guard cursor.offset < size else { return }
        // Backfill only the recent tail on first observation. Once established,
        // stream every unread record so large tool results cannot erase replies.
        let limit = 2 * 1024 * 1024
        if isInitialScan, size - cursor.offset > UInt64(limit) {
            cursor.offset = size - UInt64(limit)
            cursor.discardingLine = true
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
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
                    if let response = Self.response(from: pending, runtime: runtime,
                                                     sessionID: sessionID, offset: recordOffset) {
                        try handoff.response(response, worktree: worktree)
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
        try JSONEncoder().encode(cursor).write(to: cursorURL, options: .atomic)
    }

    static func response(from data: Data, runtime: TeamHookRuntime, sessionID: String,
                         offset: UInt64 = 0) -> WorktreeHistory.AgentResponse? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["isSidechain"] as? Bool != true else { return nil }
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
        guard !text.isEmpty, let timestamp = record["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: timestamp)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: timestamp)
        }
        guard var date else { return nil }
        if let metadata = message["internal_chat_message_metadata_passthrough"] as? [String: Any],
           let created = metadata["create_time"] as? Double, created.isFinite {
            date = Date(timeIntervalSince1970: created)
        }
        let key = SHA256.hash(data: Data("\(runtime.rawValue)\0\(sessionID)\0\(sourceID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return WorktreeHistory.AgentResponse(id: "response:\(key)", text: text, at: date, runtime: runtime.rawValue)
    }
}
