#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Creation and actual human input are retained independently of agent reports.
public struct WorktreeHistory: Codable, Sendable, Hashable {
    public struct Origin: Codable, Sendable, Hashable {
        public enum Source: String, Codable, Sendable { case user, worktree, unknown }
        public var timestamp: Double
        public var source: Source
        public var worktreePath: String?
        public var worktreeName: String?

        public init(date: Date, source: Source, worktreePath: String? = nil, worktreeName: String? = nil) {
            timestamp = date.timeIntervalSinceReferenceDate
            self.source = source
            self.worktreePath = worktreePath
            self.worktreeName = worktreeName
        }
    }

    public struct UserInput: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let timestamp: Double
        public let text: String
        public let wasTruncated: Bool
        public let runtime: String?
        public let promptDigest: String?

        fileprivate static func digest(_ prompt: String) -> String {
            SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        public init(id: UUID = UUID(), text: String, at date: Date, runtime: String? = nil) {
            self.id = id
            timestamp = date.timeIntervalSinceReferenceDate
            self.runtime = runtime
            promptDigest = Self.digest(text)
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var bytes = 0
            let prefix = text.prefix(2000).prefix { character in
                bytes += String(character).utf8.count
                return bytes <= 8000
            }
            self.text = String(prefix)
            wasTruncated = prefix.endIndex != text.endIndex
        }
    }

    public var origin: Origin?
    public private(set) var inputs: [UserInput]
    private var launchPromptDigest: String?
    private var launchRuntime: String?
    private var consumedLaunchInputID: UUID?

    public init(origin: Origin? = nil) {
        self.origin = origin
        inputs = []
    }

    public mutating func expectLaunchPrompt(_ prompt: String, runtime: String) {
        launchPromptDigest = UserInput.digest(prompt)
        launchRuntime = runtime
        consumedLaunchInputID = nil
    }

    public mutating func cancelExpectedLaunch() {
        launchPromptDigest = nil
        launchRuntime = nil
    }

    public mutating func record(_ input: UserInput) {
        guard input.id != consumedLaunchInputID, !inputs.contains(where: { $0.id == input.id }) else { return }
        if let expected = launchPromptDigest, input.runtime == launchRuntime {
            // Consume only the first prompt for the launched runtime. Later
            // human repetitions of the same task are genuine involvement.
            launchPromptDigest = nil
            launchRuntime = nil
            if input.promptDigest == expected {
                consumedLaunchInputID = input.id
                return
            }
        }
        inputs.append(input)
        inputs.sort { $0.timestamp < $1.timestamp }
        // Match the bounded checkpoint model without letting prompt text grow
        // every persisted state and paired-device snapshot indefinitely.
        if inputs.count > 128 { inputs.removeFirst(inputs.count - 128) }
    }
}

/// One chronological projection drives both native clients and all expansion modes.
public struct WorktreeTimeline: Sendable {
    public struct Event: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case creation, user, checkpoint }
        public let id: String
        public let kind: Kind
        public let timestamp: Double?
        public let title: String
        public let completed: String
        public let decisions: [String]
        public var sourceWorktreePath: String? = nil
    }

    public struct Row: Identifiable, Sendable {
        public var id: String { events[0].id }
        public let events: [Event]
        public var isGroup: Bool { events.count > 1 }
    }

    public let events: [Event]

    public init(history: WorktreeHistory?, brief: WorktreeBrief?) {
        var result = (brief?.history ?? []).map {
            Event(id: $0.id.uuidString, kind: .checkpoint, timestamp: $0.timestamp,
                  title: $0.title, completed: $0.completed, decisions: $0.decisions)
        }
        result += (history?.inputs ?? []).map {
            Event(id: $0.id.uuidString, kind: .user, timestamp: $0.timestamp,
                  title: "You sent a message", completed: $0.text + ($0.wasTruncated ? "…" : ""), decisions: [])
        }
        result = result.enumerated().sorted {
            let left = $0.element.timestamp ?? 0, right = $1.element.timestamp ?? 0
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        if let origin = history?.origin {
            let title: String
            switch origin.source {
            case .user: title = "Created by you"
            case .worktree:
                let name = origin.worktreeName ?? origin.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                title = name.map { "Created from \($0)" } ?? "Worktree created"
            case .unknown: title = "Worktree created"
            }
            result.insert(Event(id: "creation", kind: .creation, timestamp: origin.timestamp, title: title,
                completed: origin.source == .unknown ? "Creation source unavailable" : "",
                decisions: [], sourceWorktreePath: origin.worktreePath), at: 0)
        }
        events = result
    }

    public func rows(showAll: Bool) -> [Row] {
        guard !showAll, events.count > 8 else { return events.map { Row(events: [$0]) } }
        let recent = Set(events.filter { $0.kind == .checkpoint }.suffix(2).map(\.id))
        var rows: [Row] = []
        var run: [Event] = []
        func flush() {
            guard !run.isEmpty else { return }
            rows.append(Row(events: run))
            run.removeAll(keepingCapacity: true)
        }
        for (index, event) in events.enumerated() {
            if index > 0, event.kind == .checkpoint, !recent.contains(event.id) {
                run.append(event)
            } else {
                flush()
                rows.append(Row(events: [event]))
            }
        }
        flush()
        return rows
    }
}
