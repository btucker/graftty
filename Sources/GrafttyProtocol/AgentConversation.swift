import Foundation

public enum AgentConversationAction: Codable, Equatable, Sendable {
    case read, resume, messages(from: UInt64)

    // Preserve the original scalar wire format for existing viewers and hosts.
    private enum Legacy: String, Codable { case read, resume }
    private enum Keys: String, CodingKey { case messagesFrom }

    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(Legacy.self) {
            self = legacy == .read ? .read : .resume
        } else {
            let values = try decoder.container(keyedBy: Keys.self)
            self = .messages(from: try values.decode(UInt64.self, forKey: .messagesFrom))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .read, .resume:
            var value = encoder.singleValueContainer()
            try value.encode(self == .read ? Legacy.read : .resume)
        case .messages(let offset):
            var values = encoder.container(keyedBy: Keys.self)
            try values.encode(offset, forKey: .messagesFrom)
        }
    }
}

public struct AgentConversationMessages: Codable, Sendable, Equatable {
    public struct Item: Identifiable, Codable, Sendable, Equatable {
        public let id: String
        public let speaker: String
        public let text: String
        public let timestamp: Double?
        public init?(_ event: WorktreeTimeline.Event) {
            switch event.kind {
            case .user: speaker = "You"
            case .agentResponse, .agentMessage: speaker = event.title
            default: return nil
            }
            id = event.id
            text = event.completed
            timestamp = event.timestamp
        }
    }
    public let items: [Item]
    public let nextOffset: UInt64?
    public init(items: [Item], nextOffset: UInt64?) {
        self.items = items
        self.nextOffset = nextOffset
    }
}

/// Bounded, on-demand content; routine worktree snapshots carry only summaries.
public struct AgentConversationDetail: Codable, Sendable, Equatable {
    public let agentID: String
    public let assignmentID: String
    public let result: String?
    public let transcript: String?
    public let failure: String?
    public let messages: AgentConversationMessages?
    public let canResume: Bool
    public init(agentID: String, assignmentID: String, result: String?, transcript: String?, failure: String?, canResume: Bool,
                messages: AgentConversationMessages? = nil) {
        self.messages = messages
        self.agentID = agentID; self.assignmentID = assignmentID; self.result = result
        self.transcript = transcript; self.failure = failure; self.canResume = canResume
    }
}
