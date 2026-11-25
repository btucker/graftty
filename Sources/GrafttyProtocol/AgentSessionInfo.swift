import Foundation

/// Additive session classification. The legacy pane inventory remains complete.
public struct AgentSessionInfo: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let provider: String
    public let status: String
    public var sessionName: String?
    public let assignmentID: String?
    public let completionID: String?
    public let result: String?
    public let previousResults: [String]?
    public var retainedSessionName: String?
    public var retainedSlotID: String?
    public var canResume: Bool?
    public var transcriptRevision: String?
    public var presentationSessionName: String? { sessionName ?? retainedSessionName }
    /// The status the host recorded, typed; an unrecognised value from a newer host is `.unknown`.
    /// `AgentAssignmentStatus(agent:needsInput:)` additionally folds in process observation.
    public var recordedStatus: AgentAssignmentStatus { AgentAssignmentStatus(rawValue: status) ?? .unknown }
    public var isCompleted: Bool { completionID != nil || recordedStatus == .closed }
    public var failure: String?
    public var processObservation: AgentProcessObservation?
    public var outcome: String?
    public var resultCount: Int?
    public var resultsAreSummaries: Bool?
    /// Graftty launched this agent, as opposed to observing a provider the
    /// user started in an existing shell. Absent from older hosts.
    public var launched: Bool?
    /// The host can show this tab's conversation in Chat. Absent from hosts
    /// that do not serve Chat.
    public var chatAvailable: Bool?

    public init(id: String, name: String, provider: String, status: String, sessionName: String?,
                assignmentID: String? = nil, completionID: String? = nil, result: String? = nil, previousResults: [String]? = nil,
                failure: String? = nil, processObservation: AgentProcessObservation? = nil,
                outcome: String? = nil, resultCount: Int? = nil, resultsAreSummaries: Bool? = nil, retainedSessionName: String? = nil, retainedSlotID: String? = nil,
                canResume: Bool? = nil, transcriptRevision: String? = nil, launched: Bool? = nil,
                chatAvailable: Bool? = nil) {
        self.launched = launched; self.chatAvailable = chatAvailable
        self.retainedSessionName = retainedSessionName; self.retainedSlotID = retainedSlotID
        self.canResume = canResume; self.transcriptRevision = transcriptRevision
        self.failure = failure; self.processObservation = processObservation; self.outcome = outcome
        self.resultCount = resultCount; self.resultsAreSummaries = resultsAreSummaries
        self.id = id; self.name = name; self.provider = provider; self.status = status
        self.previousResults = previousResults
        self.sessionName = sessionName; self.assignmentID = assignmentID; self.completionID = completionID; self.result = result
    }
}
