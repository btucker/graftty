import Foundation

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
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
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
    case long
}

public enum FlowUrgency: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
    case critical
}

public enum FlowHoldUntil: Codable, Sendable, Equatable {
    case nextFocusBreak
    case endOfDay
    case tomorrow
    case absolute(Date)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "next_focus_break":
            self = .nextFocusBreak
        case "end_of_day":
            self = .endOfDay
        case "tomorrow":
            self = .tomorrow
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
        case .endOfDay:
            try container.encode("end_of_day")
        case .tomorrow:
            try container.encode("tomorrow")
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
    public var available: Bool
    public var running: Bool
    public var promptMode: FlowPromptMode
    public var lastUpdatedAt: Date?
    public var message: String?

    public init(
        available: Bool,
        running: Bool,
        promptMode: FlowPromptMode = .unavailable,
        lastUpdatedAt: Date? = nil,
        message: String? = nil
    ) {
        self.available = available
        self.running = running
        self.promptMode = promptMode
        self.lastUpdatedAt = lastUpdatedAt
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decode(Bool.self, forKey: .available)
        running = try container.decode(Bool.self, forKey: .running)
        promptMode = try container.decodeIfPresent(FlowPromptMode.self, forKey: .promptMode) ?? .unavailable
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

public enum FlowPromptMode: String, Codable, Sendable, Equatable {
    case systemPrompt = "system_prompt"
    case appendSystemPrompt = "append_system_prompt"
    case bootstrapPrompt = "bootstrap_prompt"
    case unavailable
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
