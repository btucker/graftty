import Foundation

public struct AgentControlRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case add, list, finish, close, resume, capability }
    public var action: Action
    public var callerWorktree: String
    public var callerAgentID: String?
    public var paneSessionName: String?
    public var agentID: String?
    public var assignmentID: UUID?
    public var completionID: UUID?
    public var result: String?
    public var name: String?
    public var worktree: String?
    public var provider: TeamHookRuntime?
    public var prompt: String?
    public var parent: String?
    public var status: ManagedAgent.Status?
    public var operationID: String?
    public var base: String?

    public init(action: Action, callerWorktree: String, callerAgentID: String? = nil,
                paneSessionName: String? = nil, agentID: String? = nil, assignmentID: UUID? = nil,
                completionID: UUID? = nil, result: String? = nil, name: String? = nil,
                worktree: String? = nil, provider: TeamHookRuntime? = nil, prompt: String? = nil,
                parent: String? = nil, status: ManagedAgent.Status? = nil, operationID: String? = nil,
                base: String? = nil) {
        self.action = action; self.callerWorktree = callerWorktree; self.callerAgentID = callerAgentID
        self.paneSessionName = paneSessionName; self.agentID = agentID; self.assignmentID = assignmentID
        self.completionID = completionID; self.result = result; self.name = name; self.worktree = worktree
        self.provider = provider; self.prompt = prompt; self.parent = parent; self.status = status
        self.operationID = operationID; self.base = base
    }
}

public struct AgentControlRecord: Codable, Sendable, Equatable {
    public let worktree: String
    public let agent: ManagedAgent
    public let operationID: String?
    public init(worktree: String, agent: ManagedAgent, operationID: String? = nil) {
        self.worktree = worktree; self.agent = agent; self.operationID = operationID
    }
}
