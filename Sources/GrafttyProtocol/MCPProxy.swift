import Foundation

/// An address, never a credential. Authority comes from the authenticated
/// connection and the parent's current policy, not this worker-supplied scope.
public struct MCPProxyScope: Codable, Sendable, Equatable {
    public var grantID: UUID
    public var generation: UInt64
    public var repositoryID: UUID
    public var worktreePath: String
    public var serverID: String
    public init(grantID: UUID, generation: UInt64, repositoryID: UUID, worktreePath: String, serverID: String) {
        self.grantID = grantID; self.generation = generation; self.repositoryID = repositoryID
        self.worktreePath = worktreePath; self.serverID = serverID
    }
}

public enum MCPProxyRequest: Codable, Sendable, Equatable {
    case open(sessionID: UUID, scope: MCPProxyScope)
    case send(sessionID: UUID, message: Data)
    case receive(sessionID: UUID)
    case close(sessionID: UUID)
}

public enum MCPProxyResponse: Codable, Sendable, Equatable {
    case opened
    /// Receipt by the bridge only; never a claim that a tool has completed.
    case accepted
    case messages([Data])
    case closed
    case error(MCPProxyError)
}

public enum MCPProxyError: String, Codable, Sendable, Error {
    case invalidRequest, unauthorized, unavailable, overloaded, outcomeUnknown
}

/// Only the parent identity and grant address cross to the worker.
public struct MCPBridgeRequest: Codable, Sendable, Equatable {
    public let parent: RemoteMacConnectionSummary.ID
    public let request: MCPProxyRequest
    public init(parent: RemoteMacConnectionSummary.ID, request: MCPProxyRequest) {
        self.parent = parent; self.request = request
    }
}

public enum MCPProxyControl {
    /// A round trip waits for worker registration before advertising readiness.
    public static let ready = Data("graftty-mcp-ready-v1".utf8)
}
