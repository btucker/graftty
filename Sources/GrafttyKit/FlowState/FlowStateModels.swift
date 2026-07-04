import Foundation
import CryptoKit
import GrafttyProtocol

public extension JSONDecoder {
    static var flowState: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public extension JSONEncoder {
    static var flowState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public enum FlowJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FlowJSONValue])
    case object([String: FlowJSONValue])

    public init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: FlowDynamicCodingKey.self) {
            var values: [String: FlowJSONValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(FlowJSONValue.self, forKey: key)
            }
            self = .object(values)
            return
        }

        if var array = try? decoder.unkeyedContainer() {
            var values: [FlowJSONValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(FlowJSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .object(values):
            var container = encoder.container(keyedBy: FlowDynamicCodingKey.self)
            for key in values.keys.sorted() {
                try container.encode(values[key], forKey: FlowDynamicCodingKey(key))
            }
        }
    }
}

public struct FlowRecommendationEnvelope: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var primary: FlowPrimaryRecommendation
    public var sameContext: [FlowSameContextItem]
    public var heldInterruptions: [FlowHeldInterruptionItem]
    public var resumeCards: [FlowResumeCard]
    public var proposedActions: [FlowProposedAction]
    public var extraFields: [String: FlowJSONValue]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        primary: FlowPrimaryRecommendation,
        sameContext: [FlowSameContextItem] = [],
        heldInterruptions: [FlowHeldInterruptionItem] = [],
        resumeCards: [FlowResumeCard] = [],
        proposedActions: [FlowProposedAction] = [],
        extraFields: [String: FlowJSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.primary = primary
        self.sameContext = sameContext
        self.heldInterruptions = heldInterruptions
        self.resumeCards = resumeCards
        self.proposedActions = proposedActions
        self.extraFields = extraFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported Flow State schema version \(schemaVersion)"
            )
        }
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        primary = try container.decode(FlowPrimaryRecommendation.self, forKey: .primary)
        sameContext = try container.decodeIfPresent([FlowSameContextItem].self, forKey: .sameContext) ?? []
        heldInterruptions = try container.decodeIfPresent([FlowHeldInterruptionItem].self, forKey: .heldInterruptions) ?? []
        resumeCards = try container.decodeIfPresent([FlowResumeCard].self, forKey: .resumeCards) ?? []
        proposedActions = try container.decodeIfPresent([FlowProposedAction].self, forKey: .proposedActions) ?? []
        extraFields = try decoder.decodeExtraFields(knownKeys: CodingKeys.knownStringValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlowDynamicCodingKey.self)
        try container.encode(schemaVersion, forKey: FlowDynamicCodingKey(CodingKeys.schemaVersion.rawValue))
        try container.encode(generatedAt, forKey: FlowDynamicCodingKey(CodingKeys.generatedAt.rawValue))
        try container.encode(primary, forKey: FlowDynamicCodingKey(CodingKeys.primary.rawValue))
        try container.encode(sameContext, forKey: FlowDynamicCodingKey(CodingKeys.sameContext.rawValue))
        try container.encode(heldInterruptions, forKey: FlowDynamicCodingKey(CodingKeys.heldInterruptions.rawValue))
        try container.encode(resumeCards, forKey: FlowDynamicCodingKey(CodingKeys.resumeCards.rawValue))
        try container.encode(proposedActions, forKey: FlowDynamicCodingKey(CodingKeys.proposedActions.rawValue))
        try container.encodeExtraFields(extraFields, knownKeys: CodingKeys.knownStringValues)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case generatedAt
        case primary
        case sameContext
        case heldInterruptions
        case resumeCards
        case proposedActions

        static var knownStringValues: Set<String> {
            Set(allCases.map(\.rawValue))
        }
    }
}

public struct FlowPrimaryRecommendation: Codable, Sendable, Equatable {
    public var worktreeRef: String?
    public var intent: FlowRecommendationIntent
    public var title: String
    public var reason: String
    public var confidence: FlowConfidence
    public var extraFields: [String: FlowJSONValue]

    public init(
        worktreeRef: String? = nil,
        intent: FlowRecommendationIntent,
        title: String,
        reason: String,
        confidence: FlowConfidence,
        extraFields: [String: FlowJSONValue] = [:]
    ) {
        self.worktreeRef = worktreeRef
        self.intent = intent
        self.title = title
        self.reason = reason
        self.confidence = confidence
        self.extraFields = extraFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktreeRef = try container.decodeIfPresent(String.self, forKey: .worktreeRef)
        intent = try container.decode(FlowRecommendationIntent.self, forKey: .intent)
        title = try container.decode(String.self, forKey: .title)
        reason = try container.decode(String.self, forKey: .reason)
        confidence = try container.decode(FlowConfidence.self, forKey: .confidence)
        extraFields = try decoder.decodeExtraFields(knownKeys: CodingKeys.knownStringValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlowDynamicCodingKey.self)
        try container.encodeIfPresent(worktreeRef, forKey: FlowDynamicCodingKey(CodingKeys.worktreeRef.rawValue))
        try container.encode(intent, forKey: FlowDynamicCodingKey(CodingKeys.intent.rawValue))
        try container.encode(title, forKey: FlowDynamicCodingKey(CodingKeys.title.rawValue))
        try container.encode(reason, forKey: FlowDynamicCodingKey(CodingKeys.reason.rawValue))
        try container.encode(confidence, forKey: FlowDynamicCodingKey(CodingKeys.confidence.rawValue))
        try container.encodeExtraFields(extraFields, knownKeys: CodingKeys.knownStringValues)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case worktreeRef
        case intent
        case title
        case reason
        case confidence

        static var knownStringValues: Set<String> {
            Set(allCases.map(\.rawValue))
        }
    }
}

public enum FlowRecommendationIntent: String, Codable, Sendable, Equatable {
    case stay
    case switchWorktree = "switch"
    case setup
    case wait
    case none
}

public enum FlowConfidence: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
}

public struct FlowSameContextItem: Codable, Sendable, Equatable {
    public var worktreeRef: String?
    public var title: String
    public var reason: String
    public var estimatedEffort: FlowEstimatedEffort?
    public var confidence: FlowConfidence?
    public var extraFields: [String: FlowJSONValue]

    public init(
        worktreeRef: String? = nil,
        title: String,
        reason: String,
        estimatedEffort: FlowEstimatedEffort? = nil,
        confidence: FlowConfidence? = nil,
        extraFields: [String: FlowJSONValue] = [:]
    ) {
        self.worktreeRef = worktreeRef
        self.title = title
        self.reason = reason
        self.estimatedEffort = estimatedEffort
        self.confidence = confidence
        self.extraFields = extraFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktreeRef = try container.decodeIfPresent(String.self, forKey: .worktreeRef)
        title = try container.decode(String.self, forKey: .title)
        reason = try container.decode(String.self, forKey: .reason)
        estimatedEffort = try container.decodeIfPresent(FlowEstimatedEffort.self, forKey: .estimatedEffort)
        confidence = try container.decodeIfPresent(FlowConfidence.self, forKey: .confidence)
        extraFields = try decoder.decodeExtraFields(knownKeys: CodingKeys.knownStringValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlowDynamicCodingKey.self)
        try container.encodeIfPresent(worktreeRef, forKey: FlowDynamicCodingKey(CodingKeys.worktreeRef.rawValue))
        try container.encode(title, forKey: FlowDynamicCodingKey(CodingKeys.title.rawValue))
        try container.encode(reason, forKey: FlowDynamicCodingKey(CodingKeys.reason.rawValue))
        try container.encodeIfPresent(estimatedEffort, forKey: FlowDynamicCodingKey(CodingKeys.estimatedEffort.rawValue))
        try container.encodeIfPresent(confidence, forKey: FlowDynamicCodingKey(CodingKeys.confidence.rawValue))
        try container.encodeExtraFields(extraFields, knownKeys: CodingKeys.knownStringValues)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case worktreeRef
        case title
        case reason
        case estimatedEffort
        case confidence

        static var knownStringValues: Set<String> {
            Set(allCases.map(\.rawValue))
        }
    }
}

public struct FlowHeldInterruptionItem: Codable, Sendable, Equatable {
    public var worktreeRef: String?
    public var title: String
    public var reason: String
    public var holdUntil: FlowHoldUntil?
    public var urgency: FlowUrgency?
    public var extraFields: [String: FlowJSONValue]

    public init(
        worktreeRef: String? = nil,
        title: String,
        reason: String,
        holdUntil: FlowHoldUntil? = nil,
        urgency: FlowUrgency? = nil,
        extraFields: [String: FlowJSONValue] = [:]
    ) {
        self.worktreeRef = worktreeRef
        self.title = title
        self.reason = reason
        self.holdUntil = holdUntil
        self.urgency = urgency
        self.extraFields = extraFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktreeRef = try container.decodeIfPresent(String.self, forKey: .worktreeRef)
        title = try container.decode(String.self, forKey: .title)
        reason = try container.decode(String.self, forKey: .reason)
        holdUntil = try container.decodeIfPresent(FlowHoldUntil.self, forKey: .holdUntil)
        urgency = try container.decodeIfPresent(FlowUrgency.self, forKey: .urgency)
        extraFields = try decoder.decodeExtraFields(knownKeys: CodingKeys.knownStringValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlowDynamicCodingKey.self)
        try container.encodeIfPresent(worktreeRef, forKey: FlowDynamicCodingKey(CodingKeys.worktreeRef.rawValue))
        try container.encode(title, forKey: FlowDynamicCodingKey(CodingKeys.title.rawValue))
        try container.encode(reason, forKey: FlowDynamicCodingKey(CodingKeys.reason.rawValue))
        try container.encodeIfPresent(holdUntil, forKey: FlowDynamicCodingKey(CodingKeys.holdUntil.rawValue))
        try container.encodeIfPresent(urgency, forKey: FlowDynamicCodingKey(CodingKeys.urgency.rawValue))
        try container.encodeExtraFields(extraFields, knownKeys: CodingKeys.knownStringValues)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case worktreeRef
        case title
        case reason
        case holdUntil
        case urgency

        static var knownStringValues: Set<String> {
            Set(allCases.map(\.rawValue))
        }
    }
}

public struct FlowResumeCard: Codable, Sendable, Equatable {
    public var worktreeRef: String?
    public var title: String
    public var summary: String
    public var nextAction: String
    public var stale: Bool
    public var extraFields: [String: FlowJSONValue]

    public init(
        worktreeRef: String? = nil,
        title: String,
        summary: String,
        nextAction: String,
        stale: Bool = false,
        extraFields: [String: FlowJSONValue] = [:]
    ) {
        self.worktreeRef = worktreeRef
        self.title = title
        self.summary = summary
        self.nextAction = nextAction
        self.stale = stale
        self.extraFields = extraFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        worktreeRef = try container.decodeIfPresent(String.self, forKey: .worktreeRef)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        nextAction = try container.decode(String.self, forKey: .nextAction)
        stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        extraFields = try decoder.decodeExtraFields(knownKeys: CodingKeys.knownStringValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlowDynamicCodingKey.self)
        try container.encodeIfPresent(worktreeRef, forKey: FlowDynamicCodingKey(CodingKeys.worktreeRef.rawValue))
        try container.encode(title, forKey: FlowDynamicCodingKey(CodingKeys.title.rawValue))
        try container.encode(summary, forKey: FlowDynamicCodingKey(CodingKeys.summary.rawValue))
        try container.encode(nextAction, forKey: FlowDynamicCodingKey(CodingKeys.nextAction.rawValue))
        try container.encode(stale, forKey: FlowDynamicCodingKey(CodingKeys.stale.rawValue))
        try container.encodeExtraFields(extraFields, knownKeys: CodingKeys.knownStringValues)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case worktreeRef
        case title
        case summary
        case nextAction
        case stale

        static var knownStringValues: Set<String> {
            Set(allCases.map(\.rawValue))
        }
    }
}

public struct FlowProposedAction: Codable, Sendable, Equatable {
    public var id: String
    public var kind: FlowProposedActionKind
    public var target: String?
    public var body: String?
    public var requiresConfirmation: Bool
    public var extraFields: [String: FlowJSONValue]

    public init(
        id: String,
        kind: FlowProposedActionKind,
        target: String? = nil,
        body: String? = nil,
        requiresConfirmation: Bool = false,
        extraFields: [String: FlowJSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.body = body
        self.requiresConfirmation = requiresConfirmation
        self.extraFields = extraFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(FlowProposedActionKind.self, forKey: .kind)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        requiresConfirmation = try container.decode(Bool.self, forKey: .requiresConfirmation)
        extraFields = try decoder.decodeExtraFields(knownKeys: CodingKeys.knownStringValues)
        try validateDecodedPayload(container: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlowDynamicCodingKey.self)
        try container.encode(id, forKey: FlowDynamicCodingKey(CodingKeys.id.rawValue))
        try container.encode(kind, forKey: FlowDynamicCodingKey(CodingKeys.kind.rawValue))
        try container.encodeIfPresent(target, forKey: FlowDynamicCodingKey(CodingKeys.target.rawValue))
        try container.encodeIfPresent(body, forKey: FlowDynamicCodingKey(CodingKeys.body.rawValue))
        try container.encode(requiresConfirmation, forKey: FlowDynamicCodingKey(CodingKeys.requiresConfirmation.rawValue))
        try container.encodeExtraFields(extraFields, knownKeys: CodingKeys.knownStringValues)
    }

    private func validateDecodedPayload(container: KeyedDecodingContainer<CodingKeys>) throws {
        switch kind {
        case .teamStatusRequest, .teamMessage, .paneCommand:
            try requireTarget(container: container)
            try requireBody(container: container)
        case .focusWorktree, .restartAgent:
            try requireTarget(container: container)
        }
    }

    private func requireTarget(container: KeyedDecodingContainer<CodingKeys>) throws {
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .target,
                in: container,
                debugDescription: "\(kind.rawValue) requires a non-empty target"
            )
        }
    }

    private func requireBody(container: KeyedDecodingContainer<CodingKeys>) throws {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .body,
                in: container,
                debugDescription: "\(kind.rawValue) requires a non-empty body"
            )
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case kind
        case target
        case body
        case requiresConfirmation

        static var knownStringValues: Set<String> {
            Set(allCases.map(\.rawValue))
        }
    }
}

public enum FlowProposedActionKind: String, Codable, Sendable, Equatable {
    case teamStatusRequest = "team_status_request"
    case teamMessage = "team_message"
    case focusWorktree = "focus_worktree"
    case restartAgent = "restart_agent"
    case paneCommand = "pane_command"
}

public enum FlowEstimatedEffort: String, Codable, Sendable, Equatable {
    case quick
    case short
    case medium
    case deep
    case unknown
}

public enum FlowUrgency: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
    case critical
}

public enum FlowHoldUntil: Codable, Sendable, Equatable {
    case nextFocusBreak
    case manualRefresh
    case absolute(Date)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "next_focus_break":
            self = .nextFocusBreak
        case "manual_refresh":
            self = .manualRefresh
        default:
            if let date = FlowISO8601.date(from: value) {
                self = .absolute(date)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown Flow State holdUntil value \(value)"
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .nextFocusBreak:
            try container.encode("next_focus_break")
        case .manualRefresh:
            try container.encode("manual_refresh")
        case let .absolute(date):
            try container.encode(FlowISO8601.string(from: date))
        }
    }
}

public struct FlowWorktreeSummary: Codable, Sendable, Equatable {
    public var worktreeRef: String
    public var updatedAt: Date
    public var summary: String
    public var nextAction: String?
    public var needsHuman: Bool

    public init(
        worktreeRef: String,
        updatedAt: Date,
        summary: String,
        nextAction: String? = nil,
        needsHuman: Bool = false
    ) {
        self.worktreeRef = worktreeRef
        self.updatedAt = updatedAt
        self.summary = summary
        self.nextAction = nextAction
        self.needsHuman = needsHuman
    }
}

public struct FlowWorktreeNote: Codable, Sendable, Equatable {
    public var worktreeRef: String
    public var updatedAt: Date
    public var body: String

    public init(worktreeRef: String, updatedAt: Date, body: String) {
        self.worktreeRef = worktreeRef
        self.updatedAt = updatedAt
        self.body = body
    }
}

public struct FlowSnooze: Codable, Sendable, Equatable {
    public var worktreeRef: String
    public var updatedAt: Date
    public var until: FlowHoldUntil
    public var reason: String?

    public init(worktreeRef: String, updatedAt: Date, until: FlowHoldUntil, reason: String? = nil) {
        self.worktreeRef = worktreeRef
        self.updatedAt = updatedAt
        self.until = until
        self.reason = reason
    }
}

public struct FlowStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var running: Bool
    public var promptMode: FlowPromptMode
    public var lastUpdatedAt: Date?
    public var message: String?

    public init(
        enabled: Bool,
        running: Bool,
        promptMode: FlowPromptMode = .unavailable,
        lastUpdatedAt: Date? = nil,
        message: String? = nil
    ) {
        self.enabled = enabled
        self.running = running
        self.promptMode = promptMode
        self.lastUpdatedAt = lastUpdatedAt
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) {
            self.enabled = enabled
        } else {
            self.enabled = try container.decode(Bool.self, forKey: .available)
        }
        running = try container.decode(Bool.self, forKey: .running)
        promptMode = try container.decodeIfPresent(FlowPromptMode.self, forKey: .promptMode) ?? .unavailable
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(running, forKey: .running)
        try container.encode(promptMode, forKey: .promptMode)
        try container.encodeIfPresent(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encodeIfPresent(message, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case available
        case running
        case promptMode
        case lastUpdatedAt
        case message
    }
}

public enum FlowPromptMode: String, Codable, Sendable, Equatable {
    case systemPrompt = "system_prompt"
    case appendSystemPrompt = "append_system_prompt"
    case bootstrapPrompt = "bootstrap_prompt"
    case unavailable
}

public struct FlowContextEnvelope: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var worktrees: [FlowWorktreeSnapshot]

    public init(schemaVersion: Int = 1, generatedAt: Date, worktrees: [FlowWorktreeSnapshot]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.worktrees = worktrees
    }
}

public struct FlowWorktreeSnapshot: Codable, Sendable, Equatable {
    public var repoPath: String
    public var repoName: String
    public var worktreeName: String
    public var worktreePath: String
    public var worktreeBranch: String
    public var worktreeState: WorktreeState
    public var worktreeKey: String
    public var worktreeRef: String
    public var displayRef: String
    public var selected: Bool
    public var focusedPaneSlotID: PaneSlotID?
    public var focusedPaneSessionID: PaneSessionID?
    public var lastUserActivityAt: Date?
    public var lastAgentActivityAt: Date?
    public var attention: FlowSnapshotAttention?
    public var agentPresence: FlowAgentPresenceSnapshot?
    public var pr: FlowPRSnapshot?
    public var git: FlowGitSnapshot?
    public var summary: FlowWorktreeSummary?
    public var summaryText: String?
    public var nextAction: String?
    public var needsHuman: Bool?
    public var note: FlowWorktreeNote?
    public var lastFlowMessageAt: Date?
    public var snooze: FlowSnooze?
    public var topicLabels: [FlowTopicLabel]
    public var clarity: FlowSnapshotClarity
    public var resumptionCostHint: FlowResumptionCostHint
    public var scoring: FlowScoringHints

    public init(
        repoPath: String,
        repoName: String,
        worktreeName: String,
        worktreePath: String,
        worktreeBranch: String,
        worktreeState: WorktreeState,
        worktreeKey: String,
        worktreeRef: String,
        displayRef: String,
        selected: Bool,
        focusedPaneSlotID: PaneSlotID? = nil,
        focusedPaneSessionID: PaneSessionID? = nil,
        lastUserActivityAt: Date? = nil,
        lastAgentActivityAt: Date? = nil,
        attention: FlowSnapshotAttention? = nil,
        agentPresence: FlowAgentPresenceSnapshot? = nil,
        pr: FlowPRSnapshot? = nil,
        git: FlowGitSnapshot? = nil,
        summary: FlowWorktreeSummary? = nil,
        summaryText: String? = nil,
        nextAction: String? = nil,
        needsHuman: Bool? = nil,
        note: FlowWorktreeNote? = nil,
        lastFlowMessageAt: Date? = nil,
        snooze: FlowSnooze? = nil,
        topicLabels: [FlowTopicLabel] = [],
        clarity: FlowSnapshotClarity,
        resumptionCostHint: FlowResumptionCostHint,
        scoring: FlowScoringHints
    ) {
        self.repoPath = repoPath
        self.repoName = repoName
        self.worktreeName = worktreeName
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
        self.worktreeState = worktreeState
        self.worktreeKey = worktreeKey
        self.worktreeRef = worktreeRef
        self.displayRef = displayRef
        self.selected = selected
        self.focusedPaneSlotID = focusedPaneSlotID
        self.focusedPaneSessionID = focusedPaneSessionID
        self.lastUserActivityAt = lastUserActivityAt
        self.lastAgentActivityAt = lastAgentActivityAt
        self.attention = attention
        self.agentPresence = agentPresence
        self.pr = pr
        self.git = git
        self.summary = summary
        self.summaryText = summaryText
        self.nextAction = nextAction
        self.needsHuman = needsHuman
        self.note = note
        self.lastFlowMessageAt = lastFlowMessageAt
        self.snooze = snooze
        self.topicLabels = topicLabels
        self.clarity = clarity
        self.resumptionCostHint = resumptionCostHint
        self.scoring = scoring
    }
}

public enum FlowWorktreeIdentity {
    public static func key(repoPath: String, worktreePath: String) -> String {
        let material = "\(absolutePath(repoPath))\u{0}\(absolutePath(worktreePath))"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefixString(16)
    }

    public static func ref(
        repoDisplayName: String,
        repoPath: String,
        worktreePath: String,
        branch: String
    ) -> String {
        let keyPrefix = key(repoPath: repoPath, worktreePath: worktreePath).prefixString(8)
        return "\(repoDisplayName)#\(keyPrefix):\(WorktreeNameSanitizer.sanitize(branch))"
    }

    private static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public struct FlowSnapshotAttention: Codable, Sendable, Equatable {
    public var text: String
    public var timestamp: Date
    public var source: AttentionSource
    public var paneSlotID: PaneSlotID?

    public init(text: String, timestamp: Date, source: AttentionSource, paneSlotID: PaneSlotID? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.source = source
        self.paneSlotID = paneSlotID
    }
}

public enum FlowSnapshotClarity: String, Codable, Sendable, Equatable {
    case clear
    case unclear
}

public enum FlowResumptionCostHint: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
}

public struct FlowTopicLabel: Codable, Sendable, Equatable, Hashable {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }
}

public struct FlowExternalSignals: Codable, Sendable, Equatable {
    public var agentPresenceByWorktreeRef: [String: FlowAgentPresenceSnapshot]
    public var agentPresenceByWorktreeKey: [String: FlowAgentPresenceSnapshot]
    public var gitByWorktreeRef: [String: FlowGitSnapshot]
    public var gitByWorktreeKey: [String: FlowGitSnapshot]
    public var prByWorktreeRef: [String: FlowPRSnapshot]
    public var prByWorktreeKey: [String: FlowPRSnapshot]
    public var activityByWorktreeRef: [String: FlowActivitySnapshot]
    public var activityByWorktreeKey: [String: FlowActivitySnapshot]

    public static let empty = FlowExternalSignals()

    public init(
        agentPresenceByWorktreeRef: [String: FlowAgentPresenceSnapshot] = [:],
        agentPresenceByWorktreeKey: [String: FlowAgentPresenceSnapshot] = [:],
        gitByWorktreeRef: [String: FlowGitSnapshot] = [:],
        gitByWorktreeKey: [String: FlowGitSnapshot] = [:],
        prByWorktreeRef: [String: FlowPRSnapshot] = [:],
        prByWorktreeKey: [String: FlowPRSnapshot] = [:],
        activityByWorktreeRef: [String: FlowActivitySnapshot] = [:],
        activityByWorktreeKey: [String: FlowActivitySnapshot] = [:]
    ) {
        self.agentPresenceByWorktreeRef = agentPresenceByWorktreeRef
        self.agentPresenceByWorktreeKey = agentPresenceByWorktreeKey
        self.gitByWorktreeRef = gitByWorktreeRef
        self.gitByWorktreeKey = gitByWorktreeKey
        self.prByWorktreeRef = prByWorktreeRef
        self.prByWorktreeKey = prByWorktreeKey
        self.activityByWorktreeRef = activityByWorktreeRef
        self.activityByWorktreeKey = activityByWorktreeKey
    }

    public func agentPresence(worktreeRef: String, worktreeKey: String) -> FlowAgentPresenceSnapshot? {
        agentPresenceByWorktreeRef[worktreeRef] ?? agentPresenceByWorktreeKey[worktreeKey]
    }

    public func git(worktreeRef: String, worktreeKey: String) -> FlowGitSnapshot? {
        gitByWorktreeRef[worktreeRef] ?? gitByWorktreeKey[worktreeKey]
    }

    public func pr(worktreeRef: String, worktreeKey: String) -> FlowPRSnapshot? {
        prByWorktreeRef[worktreeRef] ?? prByWorktreeKey[worktreeKey]
    }

    public func activity(worktreeRef: String, worktreeKey: String) -> FlowActivitySnapshot? {
        activityByWorktreeRef[worktreeRef] ?? activityByWorktreeKey[worktreeKey]
    }
}

public struct FlowAgentPresenceSnapshot: Codable, Sendable, Equatable {
    public var runtime: String?
    public var present: Bool
    public var busy: Bool
    public var waiting: Bool

    public init(runtime: String? = nil, present: Bool, busy: Bool, waiting: Bool) {
        self.runtime = runtime
        self.present = present
        self.busy = busy
        self.waiting = waiting
    }
}

public struct FlowGitSnapshot: Codable, Sendable, Equatable {
    public var dirtyCount: Int?
    public var ahead: Int?
    public var behind: Int?

    public init(dirtyCount: Int? = nil, ahead: Int? = nil, behind: Int? = nil) {
        self.dirtyCount = dirtyCount
        self.ahead = ahead
        self.behind = behind
    }
}

public struct FlowPRSnapshot: Codable, Sendable, Equatable {
    public var number: Int?
    public var state: String?
    public var ciConclusion: String?
    public var mergeState: String?
    public var urgency: FlowUrgency?

    public init(
        number: Int? = nil,
        state: String? = nil,
        ciConclusion: String? = nil,
        mergeState: String? = nil,
        urgency: FlowUrgency? = nil
    ) {
        self.number = number
        self.state = state
        self.ciConclusion = ciConclusion
        self.mergeState = mergeState
        self.urgency = urgency
    }
}

public struct FlowActivitySnapshot: Codable, Sendable, Equatable {
    public var lastUserActivityAt: Date?
    public var lastAgentActivityAt: Date?
    public var lastFlowMessageAt: Date?

    public init(lastUserActivityAt: Date? = nil, lastAgentActivityAt: Date? = nil, lastFlowMessageAt: Date? = nil) {
        self.lastUserActivityAt = lastUserActivityAt
        self.lastAgentActivityAt = lastAgentActivityAt
        self.lastFlowMessageAt = lastFlowMessageAt
    }
}

public struct FlowScoringHints: Codable, Sendable, Equatable {
    public var flowAffinity: FlowAffinityHint
    public var unlockValue: FlowUnlockValueHint
    public var riskUrgency: FlowRiskUrgencyHint
    public var completionMomentum: FlowCompletionMomentumHint
    public var interruptPenalty: FlowInterruptPenaltyHint

    public init(
        flowAffinity: FlowAffinityHint,
        unlockValue: FlowUnlockValueHint,
        riskUrgency: FlowRiskUrgencyHint,
        completionMomentum: FlowCompletionMomentumHint,
        interruptPenalty: FlowInterruptPenaltyHint
    ) {
        self.flowAffinity = flowAffinity
        self.unlockValue = unlockValue
        self.riskUrgency = riskUrgency
        self.completionMomentum = completionMomentum
        self.interruptPenalty = interruptPenalty
    }
}

public enum FlowAffinityHint: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high

    public var rawRank: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

public enum FlowUnlockValueHint: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high

    public var rawRank: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

public enum FlowRiskUrgencyHint: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
    case critical

    public var rawRank: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }
}

public enum FlowCompletionMomentumHint: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high

    public var rawRank: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

public enum FlowInterruptPenaltyHint: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high

    public var rawRank: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

private struct FlowDynamicCodingKey: CodingKey, Sendable {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension String.SubSequence {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}

private extension String {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}

private extension Decoder {
    func decodeExtraFields(knownKeys: Set<String>) throws -> [String: FlowJSONValue] {
        let container = try self.container(keyedBy: FlowDynamicCodingKey.self)
        var extraFields: [String: FlowJSONValue] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            extraFields[key.stringValue] = try container.decode(FlowJSONValue.self, forKey: key)
        }
        return extraFields
    }
}

private extension KeyedEncodingContainer where K == FlowDynamicCodingKey {
    mutating func encodeExtraFields(_ extraFields: [String: FlowJSONValue], knownKeys: Set<String>) throws {
        for key in extraFields.keys.sorted() where !knownKeys.contains(key) {
            try encode(extraFields[key], forKey: FlowDynamicCodingKey(key))
        }
    }
}

private enum FlowISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? fallbackFormatter.date(from: string)
    }

    static func string(from date: Date) -> String {
        fallbackFormatter.string(from: date)
    }
}
