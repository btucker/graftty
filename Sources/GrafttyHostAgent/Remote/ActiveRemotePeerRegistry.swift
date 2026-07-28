import Foundation
import GrafttyProtocol

/// Runtime index of remote peers with currently authenticated host-side
/// transports. Used by revocation paths to tear down sessions that were
/// already authenticated before trust was removed from `TrustedPeerStore`.
public final class ActiveRemotePeerRegistry: @unchecked Sendable {
    public struct EntryID: Hashable, Sendable {
        public let rawValue: UUID

        public init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    public struct Entry: Equatable, Sendable {
        public let id: EntryID
        public let peerID: RemoteDeviceID
        public let fingerprint: RemoteIdentityFingerprint
    }

    private struct StoredEntry {
        let entry: Entry
        let close: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var entriesByID: [EntryID: StoredEntry] = [:]
    private var entryIDsByPeerID: [RemoteDeviceID: Set<EntryID>] = [:]

    public init() {}

    @discardableResult
    public func register(
        peerID: RemoteDeviceID,
        fingerprint: RemoteIdentityFingerprint,
        close: @escaping @Sendable () async -> Void
    ) -> EntryID {
        let entryID = EntryID()
        let entry = Entry(id: entryID, peerID: peerID, fingerprint: fingerprint)
        let stored = StoredEntry(entry: entry, close: close)

        lock.lock()
        entriesByID[entryID] = stored
        entryIDsByPeerID[peerID, default: []].insert(entryID)
        lock.unlock()

        return entryID
    }

    public func unregister(entryID: EntryID) {
        lock.lock()
        removeLocked(entryID: entryID)
        lock.unlock()
    }

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entriesByID.values.map(\.entry)
    }

    public func entries(peerID: RemoteDeviceID) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let entryIDs = entryIDsByPeerID[peerID] else { return [] }
        return entryIDs.compactMap { entriesByID[$0]?.entry }
    }

    public func close(peerID: RemoteDeviceID) async {
        let entries = removeEntries(peerID: peerID)
        await close(entries)
    }

    public func close(peerID: RemoteDeviceID, fingerprint: RemoteIdentityFingerprint) async {
        let entries = removeEntries(peerID: peerID) { $0.entry.fingerprint == fingerprint }
        await close(entries)
    }

    public func closeAll() async {
        let entries = removeAllEntries()
        await close(entries)
    }

    private func removeAllEntries() -> [StoredEntry] {
        lock.lock()
        defer { lock.unlock() }
        let entries = Array(entriesByID.values)
        entriesByID.removeAll()
        entryIDsByPeerID.removeAll()
        return entries
    }

    private func removeEntries(
        peerID: RemoteDeviceID,
        matching predicate: (StoredEntry) -> Bool = { _ in true }
    ) -> [StoredEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let entryIDs = entryIDsByPeerID[peerID] else { return [] }

        var removed: [StoredEntry] = []
        for entryID in entryIDs {
            guard let stored = entriesByID[entryID], predicate(stored) else { continue }
            entriesByID.removeValue(forKey: entryID)
            removed.append(stored)
        }

        if entriesByID.values.contains(where: { $0.entry.peerID == peerID }) {
            entryIDsByPeerID[peerID] = Set(entriesByID.values
                .filter { $0.entry.peerID == peerID }
                .map(\.entry.id))
        } else {
            entryIDsByPeerID.removeValue(forKey: peerID)
        }
        return removed
    }

    private func removeLocked(entryID: EntryID) {
        guard let stored = entriesByID.removeValue(forKey: entryID) else { return }
        var entryIDs = entryIDsByPeerID[stored.entry.peerID] ?? []
        entryIDs.remove(entryID)
        if entryIDs.isEmpty {
            entryIDsByPeerID.removeValue(forKey: stored.entry.peerID)
        } else {
            entryIDsByPeerID[stored.entry.peerID] = entryIDs
        }
    }

    private func close(_ entries: [StoredEntry]) async {
        for entry in entries {
            await entry.close()
        }
    }
}
