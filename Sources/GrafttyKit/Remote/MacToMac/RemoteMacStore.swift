import Foundation
import GrafttyProtocol

@MainActor
public final class RemoteMacStore {

    public enum StoreError: Error, Equatable {
        case io(String)
        case notFound
    }

    public private(set) var remoteMacs: [RemoteMac] = []
    public private(set) var hasLoaded: Bool = false

    private let storeURL: URL

    public init(storeURL: URL = RemoteMacStore.defaultStoreURL()) {
        self.storeURL = storeURL
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
        guard !hasLoaded else { return }
        let url = storeURL
        let loaded = await Task.detached(priority: .userInitiated) {
            RemoteMacStore.readSync(from: url)
        }.value
        guard !hasLoaded else { return }
        remoteMacs = Self.sorted(loaded)
        hasLoaded = true
    }

    public func add(_ remoteMac: RemoteMac) throws {
        ensureLoaded()
        var next = remoteMacs
        if let idx = next.firstIndex(where: { Self.sameIdentity($0, remoteMac) }) {
            var updated = remoteMac
            let existing = next[idx]
            updated.addedAt = existing.addedAt
            updated.lastKnownBaseURL = remoteMac.lastKnownBaseURL ?? existing.lastKnownBaseURL
            updated.lastUsedAt = remoteMac.lastUsedAt ?? existing.lastUsedAt
            updated.lastDiscoveredAt = remoteMac.lastDiscoveredAt ?? existing.lastDiscoveredAt
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
        guard !hasLoaded else { return }
        remoteMacs = Self.sorted(Self.readSync(from: storeURL))
        hasLoaded = true
    }

    private func write(_ list: [RemoteMac]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(list)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: [.atomic])
            remoteMacs = Self.sorted(list)
        } catch {
            throw StoreError.io("\(error)")
        }
    }

    nonisolated private static func readSync(from url: URL) -> [RemoteMac] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([RemoteMac].self, from: data)
        } catch {
            // Preserve the unreadable source before returning a recoverable
            // empty model. A later pairing/save can now create a fresh file
            // without destroying the only copy of the user's prior entries.
            let milliseconds = Int(Date().timeIntervalSince1970 * 1_000)
            let backupURL = url.deletingLastPathComponent().appendingPathComponent(
                "\(url.lastPathComponent).corrupt.\(milliseconds)"
            )
            try? FileManager.default.moveItem(at: url, to: backupURL)
            return []
        }
    }

    private static func sameIdentity(_ lhs: RemoteMac, _ rhs: RemoteMac) -> Bool {
        lhs.id == rhs.id && lhs.fingerprint == rhs.fingerprint
    }

    private static func sorted(_ list: [RemoteMac]) -> [RemoteMac] {
        list.sorted {
            ($0.lastUsedAt ?? $0.lastDiscoveredAt ?? $0.addedAt)
                > ($1.lastUsedAt ?? $1.lastDiscoveredAt ?? $1.addedAt)
        }
    }
}
