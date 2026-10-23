import Foundation

/// A local staging operation, not a grant to execute skills or access MCP servers.
/// Sender identity is supplied by the authenticated channel, never this payload.
public struct RemoteSkillTransferDescriptor: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let repositoryID: String
    public let runtime: String
    public let revision: String
    public let byteCount: Int
    public init(operationID: UUID, repositoryID: String, runtime: String, revision: String, byteCount: Int) {
        self.operationID = operationID; self.repositoryID = repositoryID; self.runtime = runtime
        self.revision = revision; self.byteCount = byteCount
    }
}

public enum RemoteSkillTransferRequest: Codable, Sendable, Equatable {
    public static let maximumChunkBytes = 256 * 1024
    case begin(RemoteSkillTransferDescriptor)
    case append(operationID: UUID, offset: Int, bytes: Data)
    case finish(operationID: UUID)
    case abort(operationID: UUID)
    public var operationID: UUID {
        switch self {
        case .begin(let descriptor): descriptor.operationID
        case .append(let id, _, _), .finish(let id), .abort(let id): id
        }
    }
}

public struct RemoteSkillTransferStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case receiving, staged, aborted }
    public let descriptor: RemoteSkillTransferDescriptor
    public let receivedBytes: Int
    public let phase: Phase
    public init(descriptor: RemoteSkillTransferDescriptor, receivedBytes: Int, phase: Phase) {
        self.descriptor = descriptor; self.receivedBytes = receivedBytes; self.phase = phase
    }
}
