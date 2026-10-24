import Foundation
import GrafttyProtocol

public enum RemoteSkillTransferSender {
    /// The caller pins one authenticated destination for the entire exchange.
    /// An uncertain reply is surfaced, never retried here. The caller can rerun
    /// the same operation/snapshot to resume from the receiver's retained offset.
    public static func transfer(_ snapshot: RemoteSkillSnapshot, repositoryID: String, operationID: UUID,
                                exchange: @Sendable (RemoteSkillTransferRequest) async throws -> RemoteSkillTransferStatus) async throws -> RemoteSkillTransferStatus {
        let bytes = try snapshot.encoded()
        let descriptor = RemoteSkillTransferDescriptor(operationID: operationID, repositoryID: repositoryID,
            runtime: snapshot.runtime.rawValue, revision: RemoteSkillSnapshot.digest(bytes), byteCount: bytes.count)
        try descriptor.validated(maximumBytes: RemoteSkillSnapshot.maximumEncodedBytes)
        func checked(_ status: RemoteSkillTransferStatus) throws -> RemoteSkillTransferStatus {
            guard status.descriptor == descriptor, (0...bytes.count).contains(status.receivedBytes),
                  status.phase != .staged || status.receivedBytes == bytes.count else {
                throw RemoteSkillError("Skill transfer acknowledgement does not match this operation or the operation was aborted")
            }
            guard status.phase != .aborted else { throw RemoteSkillError("Skill transfer was aborted; start a new operation UUID with the same snapshot") }
            return status
        }
        try Task.checkCancellation()
        var status = try checked(await exchange(.begin(descriptor)))
        if status.phase == .staged { return status }
        while status.receivedBytes < bytes.count {
            try Task.checkCancellation()
            let start = status.receivedBytes
            let end = min(bytes.count, start + RemoteSkillTransferRequest.maximumChunkBytes)
            status = try checked(await exchange(.append(operationID: operationID, offset: start, bytes: bytes.subdata(in: start..<end))))
            if status.phase == .staged { return status }
            guard status.receivedBytes == end else { throw RemoteSkillError("Skill transfer returned an unexpected offset; retry the same operation to reconcile") }
        }
        try Task.checkCancellation()
        status = try checked(await exchange(.finish(operationID: operationID)))
        guard status.phase == .staged else { throw RemoteSkillError("Host did not acknowledge a staged skill revision") }
        return status
    }
}
