import Foundation

/// A claimed scope, not proof of identity. The transport must supply the peer
/// separately after authentication and checking its current pairing permission.
public struct GitDelegationScope: Codable, Sendable, Equatable {
    public let delegationID: UUID
    public let generation: UInt64
    public let repositoryID: UUID
    public let remoteWorktreeID: String
    public let refs: [String]
    public init(delegationID: UUID, generation: UInt64, repositoryID: UUID, remoteWorktreeID: String, refs: [String]) {
        self.delegationID = delegationID; self.generation = generation; self.repositoryID = repositoryID
        self.remoteWorktreeID = remoteWorktreeID; self.refs = refs
    }
}

public enum GitReplicaObjectFormat: String, Codable, Sendable { case sha1, sha256 }

public enum GitReplicationRequest: Codable, Sendable {
    case prepareReceive(scope: GitDelegationScope, objectFormat: GitReplicaObjectFormat)
}

public enum GitReplicationResponse: Codable, Sendable, Equatable {
    /// The token must be claimed on a separately authenticated data channel.
    /// It is neither a receipt nor proof that a Git process has started.
    case receiveReady(token: UUID, validForSeconds: Int)
    case error(GitReplicationError)
}

public enum GitReplicationError: String, Codable, Sendable, Error {
    case invalidRequest, unauthorized, unavailable, busy, invalidToken
}
