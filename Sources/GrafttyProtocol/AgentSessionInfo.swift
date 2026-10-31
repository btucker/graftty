import Foundation

/// Additive session classification. The legacy pane inventory remains complete.
public struct AgentSessionInfo: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let provider: String
    public let status: String
    public let sessionName: String?
    public let assignmentID: String?
    public let completionID: String?
    public let result: String?
    public let previousResults: [String]?
    public var failure: String?
    public var processObservation: AgentProcessObservation?
    public var outcome: String?
    public var resultCount: Int?
    public var resultsAreSummaries: Bool?

    public init(id: String, name: String, provider: String, status: String, sessionName: String?,
                assignmentID: String? = nil, completionID: String? = nil, result: String? = nil, previousResults: [String]? = nil,
                failure: String? = nil, processObservation: AgentProcessObservation? = nil,
                outcome: String? = nil, resultCount: Int? = nil, resultsAreSummaries: Bool? = nil) {
        self.failure = failure; self.processObservation = processObservation; self.outcome = outcome
        self.resultCount = resultCount; self.resultsAreSummaries = resultsAreSummaries
        self.id = id; self.name = name; self.provider = provider; self.status = status
        self.previousResults = previousResults
        self.sessionName = sessionName; self.assignmentID = assignmentID; self.completionID = completionID; self.result = result
    }
}
