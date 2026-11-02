import Foundation

public enum AgentConversationAction: String, Codable, Sendable { case read, resume }

/// Bounded, on-demand content; routine worktree snapshots carry only summaries.
public struct AgentConversationDetail: Codable, Sendable, Equatable {
    public let agentID: String
    public let assignmentID: String
    public let result: String?
    public let transcript: String?
    public let failure: String?
    public let canResume: Bool
    public init(agentID: String, assignmentID: String, result: String?, transcript: String?, failure: String?, canResume: Bool) {
        self.agentID = agentID; self.assignmentID = assignmentID; self.result = result
        self.transcript = transcript; self.failure = failure; self.canResume = canResume
    }
}
