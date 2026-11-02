import Foundation

// Payloads of the widest pane and worktree requests. `NotificationMessage`
// encodes the request's `type` tag beside these keys (frozen by ATTN-2.25).

/// `create_worktree`: create a worktree beside the caller's, then open it
/// and optionally launch an agent.
public struct CreateWorktreeRequest: Codable, Sendable, Equatable {
    public var callerWorktree: String
    public var worktreeName: String
    public var branchName: String
    public var existing: Bool
    public var base: String?
    public var command: String?
    public var agentRuntime: TeamHookRuntime?
    public var managedAgent: ManagedAgent?
    public var selectTab: Bool?
    public var agentPrompt: String?
    public var operationID: String?
    public var existingBranchSource: BranchSelection.ExistingSource?

    public init(callerWorktree: String, worktreeName: String, branchName: String, existing: Bool, base: String?,
                command: String?, agentRuntime: TeamHookRuntime?, agentPrompt: String?, operationID: String?, managedAgent: ManagedAgent? = nil, selectTab: Bool? = nil,
                existingBranchSource: BranchSelection.ExistingSource? = nil) {
        self.callerWorktree = callerWorktree
        self.worktreeName = worktreeName
        self.branchName = branchName
        self.existing = existing
        self.base = base
        self.command = command
        self.agentRuntime = agentRuntime
        self.agentPrompt = agentPrompt
        self.managedAgent = managedAgent
        self.selectTab = selectTab
        self.operationID = operationID
        self.existingBranchSource = existingBranchSource
    }

    public func withPrimaryAgent(provider: TeamHookRuntime, operationID: String) -> Self {
        var request = self
        var agent = ManagedAgent(name: worktreeName, provider: provider, parent: nil, status: .starting)
        agent.isPrimary = true
        agent.paneSlotID = PaneSlotID()
        agent.paneSessionID = PaneSessionID()
        agent.initialPrompt = agentPrompt
        agent.launchOperationID = operationID
        request.agentRuntime = provider
        request.managedAgent = agent
        return request
    }

    enum CodingKeys: String, CodingKey {
        case callerWorktree = "caller_worktree"
        case worktreeName = "worktree_name"
        case branchName = "branch_name"
        case existing, base, command
        case agentRuntime = "agent_runtime"
        case agentPrompt = "agent_prompt"
        case managedAgent = "managed_agent"
        case selectTab = "select_tab"
        case operationID = "operation_id"
        case existingBranchSource = "existing_branch_source"
    }
}

/// `add_pane`: split a worktree's focused pane. `agentRuntime` launches that
/// runtime through the staged prompt path shared with `create_worktree`;
/// `command` stays an arbitrary shell line.
public struct AddPaneRequest: Codable, Sendable, Equatable {
    public var path: String
    public var direction: PaneSplit
    public var command: String?
    public var agentRuntime: TeamHookRuntime?
    public var managedAgent: ManagedAgent?
    public var selectTab: Bool?
    public var agentPrompt: String?

    public init(path: String, direction: PaneSplit, command: String?, agentRuntime: TeamHookRuntime? = nil,
                agentPrompt: String? = nil, managedAgent: ManagedAgent? = nil, selectTab: Bool? = nil) {
        self.path = path
        self.direction = direction
        self.command = command
        self.agentRuntime = agentRuntime
        self.agentPrompt = agentPrompt
        self.managedAgent = managedAgent
        self.selectTab = selectTab
    }

    enum CodingKeys: String, CodingKey {
        case path, direction, command
        case agentRuntime = "agent_runtime"
        case agentPrompt = "agent_prompt"
        case managedAgent = "managed_agent"
        case selectTab = "select_tab"
    }
}
