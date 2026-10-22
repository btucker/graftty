import Foundation
import GrafttyProtocol

@MainActor
public final class RemoteMacStore {

    public enum StoreError: Error, Equatable {
        case io(String)
        case notFound
    }

    public var remoteMacs: [RemoteMac] { list.elements }
    public var hasLoaded: Bool { list.hasLoaded }

    private let list: ObservableListStore<RemoteMac>

    public init(storeURL: URL = RemoteMacStore.defaultStoreURL()) {
        list = ObservableListStore(
            file: JSONFileStore(
                fileURL: storeURL,
                dates: .iso8601,
                outputFormatting: [.prettyPrinted, .sortedKeys]
            ),
            // Preserve an unreadable file before a later pairing/save creates a
            // fresh one, so the user's prior entries are not destroyed.
            corruptFile: .moveAside,
            isLoadable: { $0.pairingProtocolVersion == RemoteAccessProtocol.version },
            areInIncreasingOrder: {
                ($0.lastUsedAt ?? $0.lastDiscoveredAt ?? $0.addedAt)
                    > ($1.lastUsedAt ?? $1.lastDiscoveredAt ?? $1.addedAt)
            }
        )
    }

    public nonisolated static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.quotably.graftty",
            isDirectory: true
        )
        return dir.appendingPathComponent("remote-macs.json")
    }

    public func loadIfNeeded() async {
        await list.loadIfNeeded()
    }

    public func add(_ remoteMac: RemoteMac) throws {
        ensureLoaded()
        var next = remoteMacs
        if let idx = next.firstIndex(where: { Self.sameIdentity($0, remoteMac) }) {
            var updated = remoteMac
            let existing = next[idx]
            updated.addedAt = existing.addedAt
            updated.lastKnownBaseURL = remoteMac.lastKnownBaseURL ?? existing.lastKnownBaseURL
            updated.routes = remoteMac.routes.isEmpty ? existing.routes : remoteMac.routes
            updated.lastSuccessfulRoute =
                remoteMac.lastSuccessfulRoute ?? existing.lastSuccessfulRoute
            updated.lastUsedAt = remoteMac.lastUsedAt ?? existing.lastUsedAt
            updated.lastDiscoveredAt = remoteMac.lastDiscoveredAt ?? existing.lastDiscoveredAt
            updated.maintenanceDestination = remoteMac.maintenanceDestination ?? existing.maintenanceDestination
            next[idx] = updated
        } else {
            next.append(remoteMac)
        }
        try write(next)
    }

    public func update(_ remoteMac: RemoteMac) throws {
        ensureLoaded()
        var next = remoteMacs
        guard let idx = next.firstIndex(where: { Self.sameIdentity($0, remoteMac) }) else {
            throw StoreError.notFound
        }
        next[idx] = remoteMac
        try write(next)
    }

    public func delete(id: RemoteDeviceID, fingerprint: RemoteIdentityFingerprint) throws {
        ensureLoaded()
        let next = remoteMacs.filter { $0.id != id || $0.fingerprint != fingerprint }
        try write(next)
    }

    public func deleteAll() throws {
        ensureLoaded()
        try write([])
    }

    public func get(id: RemoteDeviceID, fingerprint: RemoteIdentityFingerprint) throws -> RemoteMac? {
        ensureLoaded()
        return remoteMacs.first { $0.id == id && $0.fingerprint == fingerprint }
    }

    private func ensureLoaded() {
        list.ensureLoaded()
    }

    private func write(_ next: [RemoteMac]) throws {
        do {
            try list.write(next)
        } catch {
            throw StoreError.io("\(error)")
        }
    }

    private static func sameIdentity(_ lhs: RemoteMac, _ rhs: RemoteMac) -> Bool {
        lhs.id == rhs.id && lhs.fingerprint == rhs.fingerprint
    }
}
