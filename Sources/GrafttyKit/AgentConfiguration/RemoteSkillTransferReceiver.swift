import Foundation
import GrafttyProtocol

/// The authenticated transport must check current pairing/permissions on every
/// request and supply the peer fingerprint. The receiver never accepts that
/// identity from the request body. Incomplete transfers are memory-only and
/// restart from offset zero after a host restart; staged revisions are durable.
public actor RemoteSkillTransferReceiver {
    private struct Key: Hashable { let owner: RemoteMacConnectionSummary.ID; let operationID: UUID }
    private struct Upload {
        let descriptor: RemoteSkillTransferDescriptor
        let expiresAt: Date
        var bytes = Data()
        var receivedBytes = 0
        var phase: RemoteSkillTransferStatus.Phase = .receiving
        var status: RemoteSkillTransferStatus { .init(descriptor: descriptor, receivedBytes: receivedBytes, phase: phase) }
    }
    private var uploads: [Key: Upload] = [:]
    private var expiryTask: Task<Void, Never>?
    private let store: RemoteSkillStore
    private let maximumActive: Int
    private static let maximumRetained = 128
    private static let maximumReservedBytes = 48 * 1024 * 1024

    public init(directory: URL, maximumActive: Int = 2) {
        precondition((1...16).contains(maximumActive))
        store = RemoteSkillStore(directory: directory); self.maximumActive = maximumActive
    }

    deinit { expiryTask?.cancel() }

    public func handle(_ request: RemoteSkillTransferRequest, owner: RemoteMacConnectionSummary.ID,
                       repositories: Set<String>, now: Date = Date()) throws -> RemoteSkillTransferStatus {
        try Task.checkCancellation()
        uploads = uploads.filter { $0.value.expiresAt > now }
        let key = Key(owner: owner, operationID: request.operationID)
        if case .begin(let descriptor) = request {
            try descriptor.validated(maximumBytes: RemoteSkillSnapshot.maximumEncodedBytes)
            guard repositories.contains(descriptor.repositoryID) else { throw RemoteSkillError("Skill destination repository is not registered") }
            if let existing = uploads[key] {
                guard existing.descriptor == descriptor else { throw RemoteSkillError("Skill transfer operation was reused with different arguments") }
                return existing.status
            }
            let active = uploads.values.filter { $0.phase == .receiving }
            let reserved = active.reduce(0) { $0 + $1.descriptor.byteCount }
            guard active.count < maximumActive, uploads.count < Self.maximumRetained,
                  descriptor.byteCount <= Self.maximumReservedBytes - reserved else { throw RemoteSkillError("Skill transfer capacity is full; retry later") }
            let upload = Upload(descriptor: descriptor, expiresAt: now.addingTimeInterval(300))
            uploads[key] = upload
            scheduleExpiry()
            return upload.status
        }
        guard var upload = uploads[key] else { throw RemoteSkillError("Skill transfer is unknown or expired; begin it again with the same revision") }
        guard repositories.contains(upload.descriptor.repositoryID) else { throw RemoteSkillError("Skill destination repository is no longer registered") }
        switch request {
        case .begin: preconditionFailure("handled above")
        case .append(_, let offset, let bytes):
            guard upload.phase == .receiving, !bytes.isEmpty, bytes.count <= RemoteSkillTransferRequest.maximumChunkBytes,
                  offset >= 0, offset <= upload.receivedBytes, bytes.count <= upload.descriptor.byteCount - offset else {
                throw RemoteSkillError("Invalid skill transfer chunk or offset")
            }
            if offset < upload.receivedBytes {
                guard bytes.count <= upload.receivedBytes - offset,
                      upload.bytes.subdata(in: offset..<(offset + bytes.count)) == bytes else {
                    throw RemoteSkillError("Conflicting skill transfer retry")
                }
            } else {
                upload.bytes.append(bytes)
                upload.receivedBytes += bytes.count
                uploads[key] = upload
            }
        case .finish:
            if upload.phase == .staged { return upload.status }
            guard upload.phase == .receiving, upload.receivedBytes == upload.descriptor.byteCount else {
                throw RemoteSkillError("Skill transfer is incomplete or aborted")
            }
            do {
                let snapshot = try RemoteSkillSnapshot.decode(upload.bytes)
                guard snapshot.runtime.rawValue == upload.descriptor.runtime, try snapshot.revision == upload.descriptor.revision else {
                    throw RemoteSkillError("Received skill snapshot does not match its runtime or revision")
                }
                try Task.checkCancellation()
                // Length-prefix the device ID before adding the fingerprint so
                // two different identity components cannot share a namespace.
                let identity = "\(owner.deviceID.value.utf8.count):\(owner.deviceID.value):\(owner.fingerprint.display)"
                _ = try store.stage(snapshot, parentID: identity, projectID: upload.descriptor.repositoryID,
                                    beforePublish: { try Task.checkCancellation() })
                upload.phase = .staged
            } catch {
                upload.phase = .aborted; upload.bytes = Data(); uploads[key] = upload
                throw error
            }
            upload.bytes = Data(); uploads[key] = upload
        case .abort:
            if upload.phase == .receiving {
                upload.phase = .aborted; upload.bytes = Data(); uploads[key] = upload
            }
        }
        return upload.status
    }

    public func discardIncomplete() {
        uploads = uploads.filter { $0.value.phase != .receiving }
    }

    private func scheduleExpiry() {
        guard expiryTask == nil, let next = uploads.values.map(\.expiresAt).min() else { return }
        let delay = max(0.01, min(300, next.timeIntervalSinceNow))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.expire()
        }
    }

    private func expire() {
        uploads = uploads.filter { $0.value.expiresAt > Date() }
        expiryTask = nil
        scheduleExpiry()
    }
}

extension RemoteSkillTransferDescriptor {
    func validated(maximumBytes: Int) throws {
        guard repositoryID.hasPrefix("/"), repositoryID.utf8.count <= 4096,
              !repositoryID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              TeamHookRuntime(rawValue: runtime) != nil,
              revision.count == 64, revision.allSatisfy({ "0123456789abcdef".contains($0) }),
              byteCount > 0, byteCount <= maximumBytes else { throw RemoteSkillError("Invalid skill transfer declaration") }
    }
}
