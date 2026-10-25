import Foundation
import GrafttyProtocol

// MARK: - TrustedPeerStore

/// File-backed store for trusted (paired) remote peers.
///
/// Peers are persisted in a single JSON file (`trusted-peers.json`) inside
/// the given directory. The file is written atomically to avoid corruption
/// from a crash mid-write.
///
/// An NSLock serializes each instance, and an advisory file lock protects
/// complete read/modify/write transactions across app and CLI processes.
public final class TrustedPeerStore: @unchecked Sendable {

    // MARK: Errors

    public enum Error: Swift.Error, Equatable {
        /// A peer with the same fingerprint already exists in the store.
        case duplicateFingerprint
        /// No peer with the given ID was found.
        case notFound
        case changedIdentity
        case invalidStore
    }

    // MARK: Storage layout

    private static let fileName = "trusted-peers.json"

    private struct Envelope: Codable {
        var version: Int
        var peers: [TrustedPeer]
    }

    // MARK: Properties

    private let file: JSONFileStore<Envelope>
    private let lock = NSLock()

    // MARK: Init

    public init(directory: URL) {
        file = JSONFileStore(
            fileURL: directory.appendingPathComponent(Self.fileName),
            dates: .iso8601,
            outputFormatting: [.prettyPrinted, .sortedKeys]
        )
    }

    // MARK: Public API

    /// Adds a new trusted peer. Throws `.duplicateFingerprint` if a peer with
    /// the same public-key fingerprint is already stored.
    public func add(_ peer: TrustedPeer) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        var envelope = _load()
        let fingerprint = peer.fingerprint
        guard !envelope.peers.contains(where: { $0.fingerprint == fingerprint }) else {
            throw Error.duplicateFingerprint
        }
        envelope.peers.append(peer)
        try _save(envelope)
    }

    /// Persists trust established by a completed verification-code ceremony.
    ///
    /// Repeating the same ceremony is idempotent, and a newly confirmed key
    /// for the same stable device ID replaces the prior key. A fingerprint
    /// already assigned to a *different* device ID remains an error.
    public func upsertAfterPairing(_ peer: TrustedPeer) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        var envelope = _load()
        guard !envelope.peers.contains(where: {
            $0.id != peer.id && $0.fingerprint == peer.fingerprint
        }) else {
            throw Error.duplicateFingerprint
        }
        envelope.peers.removeAll { $0.id == peer.id }
        envelope.peers.append(peer)
        try _save(envelope)
    }

    /// Provider enrollment may add a new identity, but must never replace a key
    /// or restore permissions removed from an already trusted peer.
    public func enrollWithoutReplacingIdentity(_ peer: TrustedPeer) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        var envelope = try file.load() ?? Envelope(version: RemoteAccessProtocol.version, peers: [])
        guard envelope.version == RemoteAccessProtocol.version,
              Set(envelope.peers.map(\.id)).count == envelope.peers.count,
              Set(envelope.peers.map(\.fingerprint)).count == envelope.peers.count else { throw Error.invalidStore }
        if let existing = envelope.peers.first(where: { $0.id == peer.id }) {
            guard existing.publicKey == peer.publicKey, existing.kind == peer.kind else { throw Error.changedIdentity }
            return
        }
        guard !envelope.peers.contains(where: { $0.fingerprint == peer.fingerprint }) else { throw Error.duplicateFingerprint }
        envelope.peers.append(peer)
        try _save(envelope)
    }

    /// Removes the peer with the given ID. Throws `.notFound` if absent.
    public func remove(id: RemoteDeviceID) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        var envelope = _load()
        guard let idx = envelope.peers.firstIndex(where: { $0.id == id }) else {
            throw Error.notFound
        }
        envelope.peers.remove(at: idx)
        try _save(envelope)
    }

    /// Replaces the stored peer with the updated value. Throws `.notFound` if
    /// no peer with the same ID exists.
    public func update(_ peer: TrustedPeer) throws {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        var envelope = _load()
        guard let idx = envelope.peers.firstIndex(where: { $0.id == peer.id }) else {
            throw Error.notFound
        }
        envelope.peers[idx] = peer
        try _save(envelope)
    }

    /// Returns the peer with the given ID, or `nil` if not found.
    public func get(id: RemoteDeviceID) throws -> TrustedPeer? {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        let envelope = _load()
        return envelope.peers.first(where: { $0.id == id })
    }

    /// Returns `true` if any stored peer has the given fingerprint.
    public func contains(fingerprint: RemoteIdentityFingerprint) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        let envelope = _load()
        return envelope.peers.contains(where: { $0.fingerprint == fingerprint })
    }

    /// Returns the peer whose `publicKey`'s fingerprint matches the
    /// provided fingerprint, or `nil` if no peer has been paired with
    /// that key. Mirrors `PinnedHostStore.get(fingerprint:)` on the
    /// client side.
    public func get(fingerprint: RemoteIdentityFingerprint) throws -> TrustedPeer? {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        let envelope = _load()
        return envelope.peers.first(where: { $0.fingerprint == fingerprint })
    }

    /// Returns all peers, sorted by `lastSeenAt` descending (most recently
    /// seen first), with `pairedAt` descending as a tiebreak for peers that
    /// have never been seen (nil `lastSeenAt`).
    public func list() throws -> [TrustedPeer] {
        lock.lock()
        defer { lock.unlock() }
        let fileLock = try ExclusiveFileLock(url: file.fileURL.appendingPathExtension("lock"))
        defer { withExtendedLifetime(fileLock) {} }
        let envelope = _load()
        return envelope.peers.sorted { lhs, rhs in
            switch (lhs.lastSeenAt, rhs.lastSeenAt) {
            case (.some(let l), .some(let r)):
                return l > r
            case (.some, .none):
                // lhs was seen; rhs was not — lhs ranks higher
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                // Neither seen — fall back to pairedAt desc
                return lhs.pairedAt > rhs.pairedAt
            }
        }
    }

    // MARK: Default directory

    /// The production default storage directory.
    public static var defaultDirectory: URL {
        AppState.defaultDirectory
            .appendingPathComponent("Remote")
    }

    // MARK: Private helpers (call only while holding `lock`)

    /// Read failures and foreign protocol versions yield an empty envelope, so
    /// operations like revocation remain possible after corruption; malformed
    /// contents are first moved aside.
    private func _load() -> Envelope {
        guard let envelope = file.loadMovingAsideCorruptFile(),
              envelope.version == RemoteAccessProtocol.version else {
            return Envelope(version: RemoteAccessProtocol.version, peers: [])
        }
        return envelope
    }

    private func _save(_ envelope: Envelope) throws {
        try file.save(envelope)
    }
}
