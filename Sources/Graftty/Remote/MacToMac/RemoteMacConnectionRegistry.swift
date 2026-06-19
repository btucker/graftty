import Foundation
import GrafttyKit
import GrafttyProtocol

struct RemoteMacIdentity: Hashable, Sendable {
    var id: RemoteDeviceID
    var fingerprint: RemoteIdentityFingerprint

    init(id: RemoteDeviceID, fingerprint: RemoteIdentityFingerprint) {
        self.id = id
        self.fingerprint = fingerprint
    }

    init(_ remoteMac: RemoteMac) {
        self.init(id: remoteMac.id, fingerprint: remoteMac.fingerprint)
    }

    init(_ candidate: GrafttyBonjourCandidate) {
        self.init(id: candidate.deviceID, fingerprint: candidate.fingerprint)
    }
}

@MainActor
final class RemoteMacConnectionRegistry {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let identity: RemoteMacIdentity
        var remoteMac: RemoteMac
        let createdAt: Date
    }

    typealias ConnectionFactory = @MainActor @Sendable (RemoteMac, RemoteMacIdentity) async throws -> Entry

    private var entries: [RemoteMacIdentity: Entry] = [:]
    private let factory: ConnectionFactory

    var activeConnectionCount: Int {
        entries.count
    }

    init(factory: ConnectionFactory? = nil) {
        self.factory = factory ?? { remoteMac, identity in
            Entry(
                id: UUID(),
                identity: identity,
                remoteMac: remoteMac,
                createdAt: Date()
            )
        }
    }

    func connect(to remoteMac: RemoteMac) async throws -> Entry {
        let identity = RemoteMacIdentity(remoteMac)
        if var existing = entries[identity] {
            existing.remoteMac = remoteMac
            entries[identity] = existing
            return existing
        }

        let entry = try await factory(remoteMac, identity)
        entries[identity] = entry
        return entry
    }

    func disconnect(identity: RemoteMacIdentity) {
        entries[identity] = nil
    }

    func disconnectAll() {
        entries.removeAll()
    }
}
