import Foundation

public struct HostPlacementDemand: Codable, Sendable, Equatable {
    public let architecture: String
    public let cpus: Double
    public let memoryBytes: Int64
    public let diskBytes: Int64
    public init(architecture: String, cpus: Double, memoryBytes: Int64, diskBytes: Int64) {
        self.architecture = architecture; self.cpus = cpus; self.memoryBytes = memoryBytes; self.diskBytes = diskBytes
    }
}

public struct HostDevContainerRequest: Codable, Sendable, Equatable {
    public let configuration: String?
    public let skills: [HostAgentSkillRevision]?
    public let agentRuntime: String?
    public init(configuration: String? = nil, skills: [HostAgentSkillRevision]? = nil, agentRuntime: String? = nil) {
        self.configuration = configuration; self.skills = skills; self.agentRuntime = agentRuntime
    }
}

public struct HostAgentSkillRevision: Codable, Sendable, Equatable {
    public let runtime: String
    public let revision: String
    public init(runtime: String, revision: String) { self.runtime = runtime; self.revision = revision }
}

/// Immutable arguments for one idempotent host admission and worktree creation.
/// The parent identity comes from the authenticated connection, never this payload.
public struct HostPlacementIntent: Codable, Sendable, Equatable {
    public let repositoryID: String
    public let worktreeName: String
    public let branchName: String
    public let demand: HostPlacementDemand
    public let devContainer: HostDevContainerRequest?
    public init(repositoryID: String, worktreeName: String, branchName: String, demand: HostPlacementDemand, devContainer: HostDevContainerRequest? = nil) {
        self.repositoryID = repositoryID; self.worktreeName = worktreeName
        self.branchName = branchName; self.demand = demand; self.devContainer = devContainer
    }
    public var worktreePath: String { (repositoryID as NSString).appendingPathComponent(".worktrees/" + worktreeName) }
}

public enum HostPlacementRequest: Codable, Sendable, Equatable {
    case create(operationID: UUID, intent: HostPlacementIntent)
    case createInDevContainer(operationID: UUID, intent: HostPlacementIntent)
    // A distinct case prevents older workers from silently ignoring skill selections.
    case createWithAgentSkills(operationID: UUID, intent: HostPlacementIntent)
    case status(operationID: UUID)
}

public struct HostPlacementRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case preparing, created, outcomeUnknown, released
    }
    public let operationID: UUID
    public let owner: RemoteMacConnectionSummary.ID
    public let intent: HostPlacementIntent
    public let admittedAt: Date
    public let state: State
    public let worktreeID: String?
    public let paneID: String?
    public let message: String?
    public let environment: PreparedDevContainer?

    public init(operationID: UUID, owner: RemoteMacConnectionSummary.ID, intent: HostPlacementIntent, admittedAt: Date,
                state: State = .preparing, worktreeID: String? = nil, paneID: String? = nil, message: String? = nil, environment: PreparedDevContainer? = nil) {
        self.operationID = operationID; self.owner = owner; self.intent = intent; self.admittedAt = admittedAt
        self.state = state; self.worktreeID = worktreeID; self.paneID = paneID; self.message = message; self.environment = environment
    }
}
