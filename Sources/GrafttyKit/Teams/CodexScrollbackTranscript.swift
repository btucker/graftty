import Foundation
import GrafttyProtocol

/// Reads complete records from one local conversation, retaining a bounded history between rail scans.
public final class CodexScrollbackTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private let session: UUID?
    private let worktree: String
    private let codexHome: URL
    private var fileURL: URL?
    private var fileNumber: UInt64?
    private var offset: UInt64 = 0
    private var history = WorktreeHistory()
    private var discardUntilNewline = false

    public init(sessionID: String, worktree: String, codexHome: URL = CodexHomeMirror.defaultSourceDirectory()) {
        session = UUID(uuidString: sessionID)
        self.worktree = worktree
        self.codexHome = codexHome
    }

    public static func read(sessionID: String, worktree: String,
                            codexHome: URL = CodexHomeMirror.defaultSourceDirectory()) -> WorktreeTimeline? {
        CodexScrollbackTranscript(sessionID: sessionID, worktree: worktree, codexHome: codexHome).read()
    }

    public func read() -> WorktreeTimeline? {
        lock.lock()
        defer { lock.unlock() }
        guard scan(start: 0, visit: { data, session, offset in
            Self.record(data, sessionID: session, at: offset, into: &history)
            return true
        }) != nil else { return nil }
        return WorktreeTimeline(history: history, brief: nil)
    }

    /// Page forward from the verified header so a long conversation keeps its oldest prompts.
    public static func messages(sessionID: String, worktree: String, codexHome: URL,
                                from start: UInt64) -> AgentConversationMessages? {
        let reader = Self(sessionID: sessionID, worktree: worktree, codexHome: codexHome)
        var items: [AgentConversationMessages.Item] = []
        var bytes = 0
        guard let scan = reader.scan(start: start, visit: { data, session, offset in
            var record = WorktreeHistory()
            Self.record(data, sessionID: session, at: offset, into: &record)
            if !record.inputs.isEmpty || !record.responses.isEmpty {
                let visible = WorktreeTimeline(history: record, brief: nil).events.compactMap(AgentConversationMessages.Item.init)
                items.append(contentsOf: visible)
                bytes += visible.reduce(0) { $0 + $1.text.utf8.count }
            }
            return items.count < 48 && bytes < 32 * 1024
        }) else { return nil }
        return .init(items: items, nextOffset: scan.hasMore ? reader.offset : nil)
    }

    private struct ScanResult { let hasMore: Bool }

    private func scan(start requested: UInt64, visit: (Data, String, UInt64) -> Bool) -> ScanResult? {
        guard let session, let url = locate(session),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let maxRecordBytes = 4 * 1024 * 1024
        do {
            let end = try file.seekToEnd()
            if fileNumber != number || end < offset {
                try file.seek(toOffset: 0)
                // Session metadata embeds the provider's instructions, so it can span many chunks.
                var header = Data()
                var headerEnd: Data.Index?
                while headerEnd == nil, header.count < maxRecordBytes,
                      let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    let searched = header.endIndex
                    header.append(chunk)
                    headerEnd = header[searched...].firstIndex(of: 10)
                }
                guard let newline = headerEnd,
                      let record = try JSONSerialization.jsonObject(with: header[..<newline]) as? [String: Any],
                      record["type"] as? String == "session_meta", let meta = record["payload"] as? [String: Any],
                      let id = meta["id"] as? String, UUID(uuidString: id) == session,
                      let cwd = meta["cwd"] as? String, cwd.hasPrefix("/"),
                      URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path ==
                        URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path else { return nil }
                fileNumber = number
                history = WorktreeHistory()
                offset = UInt64(newline + 1)
                discardUntilNewline = false
            }
            if requested != 0 {
                guard requested >= offset, requested <= end else { return nil }
                try file.seek(toOffset: requested - 1)
                guard try file.read(upToCount: 1)?.first == 10 else { return nil }
                offset = requested
            }
            try file.seek(toOffset: offset)
            var position = offset
            var pending = Data()
            while position < end {
                guard !Task.isCancelled else { return nil }
                guard let chunk = try file.read(upToCount: Int(min(256 * 1024, end - position))), !chunk.isEmpty else { break }
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let newline = chunk[start...].firstIndex(of: 10)
                    let stop = newline ?? chunk.endIndex
                    if !discardUntilNewline {
                        if pending.count + stop - start > maxRecordBytes {
                            pending.removeAll(keepingCapacity: false)
                            discardUntilNewline = true
                        } else {
                            pending.append(contentsOf: chunk[start..<stop])
                        }
                    }
                    if let newline {
                        let keepReading = discardUntilNewline || visit(pending, session.uuidString.lowercased(), offset)
                        pending.removeAll(keepingCapacity: true)
                        discardUntilNewline = false
                        start = newline + 1
                        offset = position + UInt64(start)
                        if !keepReading { return ScanResult(hasMore: offset < end) }
                    } else {
                        // Retry an incomplete record on append. Oversized tool records need no replay.
                        if discardUntilNewline { offset = position + UInt64(stop) }
                        break
                    }
                }
                position += UInt64(chunk.count)
            }
            return ScanResult(hasMore: false)
        } catch { return nil }
    }

    private func locate(_ session: UUID) -> URL? {
        let manager = FileManager.default
        if let fileURL, manager.fileExists(atPath: fileURL.path) { return fileURL }
        let suffix = "-\(session.uuidString.lowercased()).jsonl"
        let files = manager.enumerator(at: codexHome.appendingPathComponent("sessions"),
                                       includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        fileURL = files?.lazy.compactMap { $0 as? URL }.first { $0.lastPathComponent.lowercased().hasSuffix(suffix) }
        return fileURL
    }

    private static func record(_ data: Data, sessionID: String, at offset: UInt64, into history: inout WorktreeHistory) {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let input = Self.userInput(from: record, sessionID: sessionID, offset: offset) { history.record(input) }
        if let response = AgentResponseCapture.response(from: record, runtime: .codex, sessionID: sessionID, offset: offset) {
            history.record(response)
        }
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
