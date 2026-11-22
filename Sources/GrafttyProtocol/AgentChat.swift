import Foundation

/// Identifies the one live conversation behind an agent tab. A host rejects
/// any action whose binding no longer matches the tab's running agent.
public struct AgentChatBinding: Codable, Sendable, Hashable {
    public let agentID: String
    public let assignmentID: String
    public let conversationID: String

    public init(agentID: String, assignmentID: String, conversationID: String) {
        self.agentID = agentID
        self.assignmentID = assignmentID
        self.conversationID = conversationID
    }
}

public struct AgentChatItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case user, agent, reasoning, command, fileChange, tool, notice
    }

    /// The provider's item ID. One ID is one row, whichever view produced it.
    public let id: String
    public let turnID: String?
    public let kind: Kind
    /// Message text, command line, or a one-line summary of the activity.
    public var text: String
    /// Secondary content such as command output.
    public var detail: String?
    /// The submission ID of a message sent from Chat.
    public let submissionID: String?
    public var isComplete: Bool

    public init(
        id: String, turnID: String?, kind: Kind, text: String, detail: String? = nil,
        submissionID: String? = nil, isComplete: Bool
    ) {
        self.id = id
        self.turnID = turnID
        self.kind = kind
        self.text = text
        self.detail = detail
        self.submissionID = submissionID
        self.isComplete = isComplete
    }
}

/// A decision the provider is waiting for, such as a command approval.
public struct AgentChatPendingRequest: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case commandApproval, fileChangeApproval, other
    }

    public let id: String
    public let kind: Kind
    public let summary: String
    public let detail: String?
    /// False when only the provider's own terminal interface can answer it.
    public let canAnswerInChat: Bool

    public init(id: String, kind: Kind, summary: String, detail: String? = nil, canAnswerInChat: Bool) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.canAnswerInChat = canAnswerInChat
    }
}

public enum AgentChatDecision: String, Codable, Sendable {
    case accept, acceptForSession, decline, cancel
}

public enum AgentChatTurnState: String, Codable, Sendable {
    case idle, active, waitingOnRequest
}

public struct AgentChatCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let argumentHint: String?
    /// The literal text that choosing this command puts in the draft.
    public let invocation: String

    public init(name: String, description: String, argumentHint: String? = nil, invocation: String? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.invocation = invocation ?? "/\(name)"
    }
}

/// The slash menu's state for a draft. A slash opens the menu only as the
/// first character of the prompt, and only until the command name ends.
public struct AgentChatSlashQuery: Sendable, Equatable {
    public let matches: [AgentChatCommand]

    public init?(draft: String, commands: [AgentChatCommand]) {
        guard draft.hasPrefix("/"), !commands.isEmpty else { return nil }
        let typed = draft.dropFirst()
        guard !typed.contains(where: \.isWhitespace) else { return nil }
        let query = typed.lowercased()
        let names = commands.map { ($0, $0.name.lowercased()) }
        let prefixed = names.filter { $0.1.hasPrefix(query) }.map(\.0)
        let contained = names.filter { !$0.1.hasPrefix(query) && $0.1.contains(query) }.map(\.0)
        matches = prefixed + contained
        if matches.isEmpty { return nil }
    }

    /// The draft after choosing `command`: its invocation, ready for arguments.
    public static func draft(choosing command: AgentChatCommand) -> String {
        command.invocation + " "
    }
}

/// Everything a viewer needs to draw Chat for a conversation, as of `sequence`.
public struct AgentChatSnapshot: Codable, Sendable, Equatable {
    public let binding: AgentChatBinding
    public var items: [AgentChatItem]
    public var turnState: AgentChatTurnState
    public var requests: [AgentChatPendingRequest]
    public var commands: [AgentChatCommand]
    /// The last update folded into this snapshot.
    public var sequence: Int
    /// Set once the conversation can no longer accept input from this binding.
    public var endedReason: String?

    public init(
        binding: AgentChatBinding, items: [AgentChatItem] = [], turnState: AgentChatTurnState = .idle,
        requests: [AgentChatPendingRequest] = [], commands: [AgentChatCommand] = [],
        sequence: Int = 0, endedReason: String? = nil
    ) {
        self.binding = binding
        self.items = items
        self.turnState = turnState
        self.requests = requests
        self.commands = commands
        self.sequence = sequence
        self.endedReason = endedReason
    }
}

public enum AgentChatEvent: Codable, Sendable, Equatable {
    /// Adds the item, or replaces the row that has the same ID.
    case item(AgentChatItem)
    case textDelta(itemID: String, turnID: String?, kind: AgentChatItem.Kind, delta: String)
    case turnState(AgentChatTurnState)
    case requestOpened(AgentChatPendingRequest)
    case requestResolved(id: String)
    /// The complete command list. It replaces the previous one.
    case commands([AgentChatCommand])
    /// The provider left this conversation, for example after a resume in its terminal.
    case ended(reason: String)
}

public struct AgentChatUpdate: Codable, Sendable, Equatable {
    public let sequence: Int
    public let event: AgentChatEvent

    public init(sequence: Int, event: AgentChatEvent) {
        self.sequence = sequence
        self.event = event
    }
}

/// Folds updates into a snapshot. The host and every viewer use the same
/// reducer, so a reconnect that replays updates cannot duplicate a row.
public struct AgentChatTranscript: Sendable, Equatable {
    public private(set) var snapshot: AgentChatSnapshot

    public init(snapshot: AgentChatSnapshot) {
        self.snapshot = snapshot
    }

    /// Applies an update unless the snapshot already includes it.
    @discardableResult
    public mutating func apply(_ update: AgentChatUpdate) -> Bool {
        guard update.sequence > snapshot.sequence else { return false }
        apply(update.event)
        snapshot.sequence = update.sequence
        return true
    }

    public mutating func apply(_ event: AgentChatEvent) {
        switch event {
        case .item(let item):
            upsert(item)
        case .textDelta(let itemID, let turnID, let kind, let delta):
            if let index = snapshot.items.firstIndex(where: { $0.id == itemID }) {
                guard !snapshot.items[index].isComplete else { return }
                snapshot.items[index].text += delta
            } else {
                snapshot.items.append(AgentChatItem(
                    id: itemID, turnID: turnID, kind: kind, text: delta, isComplete: false
                ))
            }
        case .turnState(let state):
            snapshot.turnState = state
        case .requestOpened(let request):
            if let index = snapshot.requests.firstIndex(where: { $0.id == request.id }) {
                snapshot.requests[index] = request
            } else {
                snapshot.requests.append(request)
            }
        case .requestResolved(let id):
            snapshot.requests.removeAll { $0.id == id }
        case .commands(let commands):
            snapshot.commands = commands
        case .ended(let reason):
            snapshot.endedReason = reason
            snapshot.requests = []
            snapshot.turnState = .idle
        }
    }

    private mutating func upsert(_ item: AgentChatItem) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == item.id }) else {
            snapshot.items.append(item)
            return
        }
        // A start notice can arrive after the completed item when history and
        // live events overlap. The completed row is the newer one.
        if snapshot.items[index].isComplete && !item.isComplete { return }
        snapshot.items[index] = item
    }
}

public enum AgentChatRejection: String, Codable, Sendable {
    /// A turn is already running, or another viewer's submission won the race.
    case busy
    /// The conversation ended or the agent moved to another one.
    case ended
    case staleBinding
    case notController
    case unavailable
}

public enum AgentChatSubmissionResult: Codable, Sendable, Equatable {
    case accepted
    case rejected(AgentChatRejection)
    /// The provider may have received the prompt. It is never resent automatically.
    case uncertain
}

public struct AgentChatSubmission: Codable, Sendable, Equatable {
    public let binding: AgentChatBinding
    /// Chosen by the viewer. A retry with the same ID never starts a second turn.
    public let submissionID: String
    public let text: String

    public init(binding: AgentChatBinding, submissionID: String, text: String) {
        self.binding = binding
        self.submissionID = submissionID
        self.text = text
    }
}

/// What a viewer sends on the agent chat channel.
public enum AgentChatClientMessage: Codable, Sendable, Equatable {
    case open(worktreePath: String, agentID: String)
    case submit(AgentChatSubmission)
    case answer(binding: AgentChatBinding, requestID: String, decision: AgentChatDecision)

    /// Bounds one encoded viewer message. A draft is the only large field.
    public static let maximumEncodedBytes = 1 << 20
}

/// What the host sends on the agent chat channel.
public enum AgentChatServerMessage: Codable, Sendable, Equatable {
    case snapshot(AgentChatSnapshot)
    case update(AgentChatUpdate)
    case submitted(submissionID: String, result: AgentChatSubmissionResult)
    case answered(requestID: String, accepted: Bool)
    /// Chat cannot attach to this tab. The terminal stays usable.
    case unavailable(reason: String)
}

public enum AgentChatFeed: Sendable {
    case attached(AgentChatSnapshot, AsyncStream<AgentChatUpdate>)
    case unavailable(String)
}

/// How a Chat view reaches its tab's session: directly on the Mac that hosts
/// the agent, or over the paired connection from another viewer.
public struct AgentChatConnection: Sendable {
    public var open: @Sendable () async -> AgentChatFeed
    public var submit: @Sendable (AgentChatSubmission) async -> AgentChatSubmissionResult
    public var answer: @Sendable (AgentChatBinding, String, AgentChatDecision) async -> Bool

    public init(
        open: @escaping @Sendable () async -> AgentChatFeed,
        submit: @escaping @Sendable (AgentChatSubmission) async -> AgentChatSubmissionResult,
        answer: @escaping @Sendable (AgentChatBinding, String, AgentChatDecision) async -> Bool
    ) {
        self.open = open
        self.submit = submit
        self.answer = answer
    }
}
