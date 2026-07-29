import Foundation
import GrafttyProtocol

// MARK: - PinnedHost

/// A remote host that the client has successfully paired with.
///
/// `PinnedHost` is not UI-gated; it is a pure value type shared by
/// macOS and mobile clients.
public struct PinnedHost: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The host's stable device identifier.
    public let id: RemoteDeviceID

    /// The host device category.
    public let kind: RemoteDeviceKind

    /// Full public key (not just fingerprint) so the attach handshake can
    /// verify host responses without an additional round-trip.
    public let publicKey: RemoteIdentityPublicKey

    /// Human-readable label for the host.
    public var displayName: String

    /// When this host was first pinned.
    public let pinnedAt: Date

    /// Most recent successful connection time.
    public var lastConnectedAt: Date?

    /// Pairing endpoint retained for pairing UI and diagnostics.
    public var pairingURL: URL

    /// Signed ways to reach the host's paired-access listener.
    public var routes: [RemoteConnectionRoute]

    /// The most recently successful route, preferred on the next connection.
    public var lastSuccessfulRoute: RemoteConnectionRoute?

    /// SHA-256 fingerprint derived from the host's public key.
    public var fingerprint: RemoteIdentityFingerprint {
        RemoteIdentityFingerprint(of: publicKey)
    }

    public init(
        id: RemoteDeviceID,
        kind: RemoteDeviceKind,
        publicKey: RemoteIdentityPublicKey,
        displayName: String,
        pinnedAt: Date,
        lastConnectedAt: Date? = nil,
        pairingURL: URL,
        routes: [RemoteConnectionRoute] = [],
        lastSuccessfulRoute: RemoteConnectionRoute? = nil
    ) {
        self.id = id
        self.kind = kind
        self.publicKey = publicKey
        self.displayName = displayName
        self.pinnedAt = pinnedAt
        self.lastConnectedAt = lastConnectedAt
        self.pairingURL = pairingURL
        self.routes = routes
        self.lastSuccessfulRoute = lastSuccessfulRoute
    }
}

// MARK: - PinnedHostStore

/// File-backed store for hosts the client has paired with.
///
/// Hosts are persisted in a single JSON file (`pinned-hosts.json`) inside
/// the given directory. The file is written atomically to avoid corruption
/// from a crash mid-write.
///
/// Thread safety is achieved via an `NSLock`.
// TODO: Extract JSONFileStore<T> helper before the network layer lands.
public final class PinnedHostStore: @unchecked Sendable {

    // MARK: Errors

    public enum Error: Swift.Error, Equatable {
        /// A host with the same fingerprint already exists in the store.
        case duplicateFingerprint
        /// No host with the given ID was found.
        case notFound
    }

    // MARK: Storage layout

    private static let fileName = "pinned-hosts.json"

    private struct Envelope: Codable {
        var version: Int
        var hosts: [PinnedHost]
    }

    // MARK: Properties

    private let directory: URL
    private let lock = NSLock()

    // MARK: Init

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Public API

    /// Adds a new pinned host. Throws `.duplicateFingerprint` if a host with
    /// the same public-key fingerprint is already stored.
    public func add(_ host: PinnedHost) throws {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try _load()
        let fingerprint = host.fingerprint
        guard !envelope.hosts.contains(where: { $0.fingerprint == fingerprint }) else {
            throw Error.duplicateFingerprint
        }
        envelope.hosts.append(host)
        try _save(envelope)
    }

    /// Persists trust established by a completed verification-code ceremony.
    ///
    /// Repeating the same ceremony is idempotent, and a newly confirmed key
    /// for the same stable device ID replaces the prior key. A fingerprint
    /// already assigned to a *different* device ID remains an error.
    public func upsertAfterPairing(_ host: PinnedHost) throws {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try _load()
        guard !envelope.hosts.contains(where: {
            $0.id != host.id && $0.fingerprint == host.fingerprint
        }) else {
            throw Error.duplicateFingerprint
        }
        envelope.hosts.removeAll { $0.id == host.id }
        envelope.hosts.append(host)
        try _save(envelope)
    }

    /// Replaces the stored host with the updated value. Throws `.notFound` if
    /// no host with the same ID exists.
    public func update(_ host: PinnedHost) throws {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try _load()
        guard let idx = envelope.hosts.firstIndex(where: { $0.id == host.id }) else {
            throw Error.notFound
        }
        envelope.hosts[idx] = host
        try _save(envelope)
    }

    /// Removes the host with the given ID. Throws `.notFound` if absent.
    public func remove(id: RemoteDeviceID) throws {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try _load()
        guard let idx = envelope.hosts.firstIndex(where: { $0.id == id }) else {
            throw Error.notFound
        }
        envelope.hosts.remove(at: idx)
        try _save(envelope)
    }

    /// Returns the host with the given ID, or `nil` if not found.
    public func get(id: RemoteDeviceID) throws -> PinnedHost? {
        lock.lock()
        defer { lock.unlock() }
        let envelope = try _load()
        return envelope.hosts.first(where: { $0.id == id })
    }

    /// Returns the host with the given fingerprint, or `nil` if not found.
    public func get(fingerprint: RemoteIdentityFingerprint) throws -> PinnedHost? {
        lock.lock()
        defer { lock.unlock() }
        let envelope = try _load()
        return envelope.hosts.first(where: { $0.fingerprint == fingerprint })
    }

    /// Returns all hosts, sorted by `lastConnectedAt` descending (most recently
    /// connected first), with `pinnedAt` descending as a tiebreak.
    public func list() throws -> [PinnedHost] {
        lock.lock()
        defer { lock.unlock() }
        let envelope = try _load()
        return envelope.hosts.sorted { lhs, rhs in
            switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
            case (.some(let l), .some(let r)):
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.pinnedAt > rhs.pinnedAt
            }
        }
    }

    // MARK: Default directory

    /// The production default storage directory.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }

    // MARK: Private helpers (call only while holding `lock`)

    private func _load() throws -> Envelope {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return Envelope(version: RemoteAccessProtocol.version,hosts: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.version == RemoteAccessProtocol.version else {
                return Envelope(version: RemoteAccessProtocol.version, hosts: [])
            }
            return envelope
        } catch {
            // Corrupt file: back it up and return an empty envelope so callers can recover.
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            let backupURL = directory.appendingPathComponent("\(Self.fileName).corrupt.\(ms)")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return Envelope(version: RemoteAccessProtocol.version,hosts: [])
        }
    }

    private func _save(_ envelope: Envelope) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
