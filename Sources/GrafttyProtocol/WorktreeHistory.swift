#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Creation, human input and visible agent responses survive independently of agent reports.
public struct WorktreeHistory: Codable, Sendable, Hashable {
    /// @spec CONTEXT-40
    /// When a provider emits a visible agent response, the application shall retain it once in worktree history independently of attention, order it between human inputs and other events by its original time, and include it in one expandable turn summary with the captured text available on Mac and mobile.
    public struct AgentResponse: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let timestamp: Double
        public let text: String
        public let runtime: String
        public let wasTruncated: Bool
        /// Older histories lack provider session and completion metadata.
        public let sessionID: String?
        public var isFinal: Bool?

        public init(id: String, text: String, at date: Date, runtime: String,
                    sessionID: String? = nil, isFinal: Bool? = nil) {
            self.id = id
            timestamp = date.timeIntervalSinceReferenceDate
            self.runtime = runtime
            self.sessionID = sessionID
            self.isFinal = isFinal
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var bytes = 0
            let prefix = trimmed.prefix(4000).prefix { character in
                bytes += String(character).utf8.count
                return bytes <= 16_000
            }
            self.text = String(prefix)
            wasTruncated = prefix.endIndex != trimmed.endIndex
        }
    }

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
        /// Absent in older history or mixed prompts. Those are classified at projection.
        public let source: WorktreePromptContent.Part.Source?

        fileprivate static func digest(_ prompt: String) -> String {
            SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        public init(id: UUID = UUID(), text: String, at date: Date, runtime: String? = nil) {
            self.id = id
            timestamp = date.timeIntervalSinceReferenceDate
            self.runtime = runtime
            promptDigest = Self.digest(text)
            let parts = WorktreePromptContent.parts(in: text)
            // Capture provenance before bounding text, so truncating a long
            // provider envelope cannot turn it into apparent human input.
            source = parts.count == 1 ? parts[0].source : (parts.isEmpty ? .generated : nil)
            let text = (parts.count == 1 ? parts[0].text : WorktreePromptContent.retainedText(from: parts))
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
    public private(set) var responses: [AgentResponse] = []
    private var launchPromptDigest: String?
    private var launchRuntime: String?
    private var consumedLaunchInputID: UUID?

    public init(origin: Origin? = nil) {
        self.origin = origin
        inputs = []
    }

    private enum CodingKeys: String, CodingKey {
        case origin, inputs, responses, launchPromptDigest, launchRuntime, consumedLaunchInputID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        origin = try values.decodeIfPresent(Origin.self, forKey: .origin)
        inputs = try values.decodeIfPresent([UserInput].self, forKey: .inputs) ?? []
        responses = try values.decodeIfPresent([AgentResponse].self, forKey: .responses) ?? []
        launchPromptDigest = try values.decodeIfPresent(String.self, forKey: .launchPromptDigest)
        launchRuntime = try values.decodeIfPresent(String.self, forKey: .launchRuntime)
        consumedLaunchInputID = try values.decodeIfPresent(UUID.self, forKey: .consumedLaunchInputID)
    }

    public mutating func record(_ response: AgentResponse) {
        guard !response.text.isEmpty else { return }
        if let index = responses.firstIndex(where: { $0.id == response.id }) {
            // Completion also freezes the final text and session metadata against
            // stale partial deliveries, including handoffs from older app versions.
            if responses[index].isFinal == true, response.isFinal != true { return }
            responses[index] = response
        } else {
            responses.append(response)
        }
        responses.sort { $0.timestamp < $1.timestamp }
        if responses.count > 128 { responses.removeFirst(responses.count - 128) }
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
        public enum Kind: Sendable { case creation, user, agentMessage, agentResponse, checkpoint }
        public let id: String
        public let kind: Kind
        public let timestamp: Double?
        public let title: String
        public let completed: String
        public let decisions: [String]
        public var isExplicitEntry: Bool = false
        public var sourceWorktreePath: String? = nil
        public var responseSessionID: String? = nil
        public var isFinalResponse: Bool? = nil

        public var sourceWorktreeName: String? {
            sourceWorktreePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
    }

    /// @spec CONTEXT-25
    /// A row is one event, a fold of older checkpoints, a run of peer messages
    /// from one sender, an agent turn, or a run of nearby human inputs.
    public struct Row: Identifiable, Sendable {
        public enum Kind: Sendable { case event, folded, peerMessages, inputs, agentTurn }
        public struct Entry: Identifiable, Equatable, Sendable {
            public var id: String { event.id }
            public let event: Event
            public let count: Int
        }
        public var id: String { events[0].id }
        public let kind: Kind
        public let events: [Event]
        /// Peer runs collapse consecutive exact duplicates; other rows keep every event.
        public let entries: [Entry]
        public var isGroup: Bool { kind == .folded }
        public let isComplete: Bool

        /// Intermediate updates stay available on expansion, but do not enter the model prompt.
        public var summaryInput: String {
            guard let last = events.last, events.count > 1 else { return events[0].completed }
            return "First agent message:\n\(events[0].completed)\n\nLast agent message:\n\(last.completed)"
        }

        public var fullText: String { events.map(\.completed).joined(separator: "\n\n") }

        init(kind: Kind, events: [Event], isComplete: Bool = true) {
            self.kind = kind
            self.events = events
            self.isComplete = isComplete
            var entries: [Entry] = []
            for event in events {
                if kind == .peerMessages, let last = entries.last, last.event.completed == event.completed {
                    entries[entries.count - 1] = Entry(event: last.event, count: last.count + 1)
                } else {
                    entries.append(Entry(event: event, count: 1))
                }
            }
            self.entries = entries
        }

        init(_ event: Event) {
            switch event.kind {
            case .user: self.init(kind: .inputs, events: [event])
            case .agentMessage: self.init(kind: .peerMessages, events: [event])
            case .agentResponse: self.init(kind: .agentTurn, events: [event], isComplete: event.isFinalResponse != false)
            case .creation, .checkpoint: self.init(kind: .event, events: [event])
            }
        }

        func merging(_ event: Event) -> Row? {
            guard let last = events.last, last.kind == event.kind else { return nil }
            switch kind {
            case .inputs where (event.timestamp ?? 0) - (last.timestamp ?? 0) <= 600,
                 .peerMessages where (event.sourceWorktreePath ?? event.title) == (last.sourceWorktreePath ?? last.title):
                return Row(kind: kind, events: events + [event])
            default: return nil
            }
        }
    }

    public let events: [Event]

    public init(history: WorktreeHistory?, brief: WorktreeBrief?) {
        var previousDecisions: Set<String> = []
        var result = (brief?.history ?? []).map { checkpoint in
            let isExplicit = checkpoint.isExplicitEntry == true
            let introduced = isExplicit ? [] : checkpoint.decisions.filter { !previousDecisions.contains($0) }
            if !isExplicit { previousDecisions = Set(checkpoint.decisions) }
            return Event(id: checkpoint.id.uuidString, kind: .checkpoint, timestamp: checkpoint.timestamp,
                         title: checkpoint.title, completed: checkpoint.completed, decisions: introduced,
                         isExplicitEntry: isExplicit)
        }
        result += (history?.inputs ?? []).flatMap { input -> [Event] in
            let parts = input.source.map { [WorktreePromptContent.Part(source: $0, text: input.text)] }
                ?? WorktreePromptContent.parts(in: input.text)
            return parts.enumerated().compactMap { index, part in
                let kind: Event.Kind
                let title: String
                var sourcePath: String? = nil
                switch part.source {
                case .user: kind = .user; title = "You sent a message"
                case .agent(let sender):
                    kind = .agentMessage
                    title = sender.map { "Message from \($0)" } ?? "Agent sent a message"
                    sourcePath = Self.worktreePath(from: sender)
                case .generated: return nil
                }
                return Event(id: input.id.uuidString + (parts.count > 1 ? ":\(index)" : ""),
                    kind: kind, timestamp: input.timestamp, title: title,
                    completed: part.text + (input.wasTruncated && index == parts.count - 1 ? "…" : ""),
                    decisions: [], sourceWorktreePath: sourcePath)
            }
        }
        result += (history?.responses ?? []).map { response in
            Event(id: response.id, kind: .agentResponse, timestamp: response.timestamp,
                  title: response.runtime == "claude" ? "Claude" : "Codex",
                  completed: response.text + (response.wasTruncated ? "…" : ""), decisions: [],
                  responseSessionID: response.runtime + ":" + (response.sessionID ?? "legacy"),
                  isFinalResponse: response.isFinal)
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

    private static func worktreePath(from sender: String?) -> String? {
        guard let sender, sender.hasPrefix("/"),
              !sender.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if let separator = sender.lastIndex(of: "#") {
            let agent = sender[sender.index(after: separator)...]
            if agent == "codex" || agent == "claude" || agent.hasPrefix("codex-") || agent.hasPrefix("claude-") {
                return String(sender[..<separator])
            }
        }
        return sender
    }

    public func rows(showAll: Bool) -> [Row] {
        let folds = !showAll && events.count > 8
        let recent = Set(events.filter { $0.kind == .checkpoint }.suffix(2).map(\.id))
        var rows: [Row] = []
        var turns: [String: Int] = [:]
        var run: [Event] = []
        func flush() {
            guard !run.isEmpty else { return }
            rows.append(run.count > 1 ? Row(kind: .folded, events: run) : Row(run[0]))
            run.removeAll(keepingCapacity: true)
        }
        for (index, event) in events.enumerated() {
            if event.kind == .user || event.kind == .agentMessage {
                // An interrupted turn still gets a summary once the next input arrives.
                for rowIndex in turns.values {
                    rows[rowIndex] = Row(kind: .agentTurn, events: rows[rowIndex].events)
                }
                turns.removeAll()
            }
            if folds, index > 0, event.kind == .checkpoint, !event.isExplicitEntry, !recent.contains(event.id) {
                run.append(event)
            } else {
                flush()
                if event.kind == .agentResponse, let session = event.responseSessionID {
                    if let rowIndex = turns[session] {
                        rows[rowIndex] = Row(kind: .agentTurn, events: rows[rowIndex].events + [event],
                                             isComplete: event.isFinalResponse != false)
                    } else {
                        turns[session] = rows.count
                        rows.append(Row(event))
                    }
                    if event.isFinalResponse == true { turns[session] = nil }
                } else if let merged = rows.last?.merging(event) {
                    rows[rows.count - 1] = merged
                } else {
                    rows.append(Row(event))
                }
            }
        }
        flush()
        return rows
    }
}
