import Foundation
import GrafttyProtocol

// MARK: - TrustedPeerStore

/// File-backed store for trusted (paired) remote peers.
///
/// Peers are persisted in a single JSON file (`trusted-peers.json`) inside
/// the given directory. The file is written atomically to avoid corruption
/// from a crash mid-write.
///
/// Thread safety is achieved via an `NSLock`; the store is not high-throughput
/// so a simple lock beats the complexity of async isolation.
public final class TrustedPeerStore: @unchecked Sendable {

    // MARK: Errors

    public enum Error: Swift.Error, Equatable {
        /// A peer with the same fingerprint already exists in the store.
        case duplicateFingerprint
        /// No peer with the given ID was found.
        case notFound
    }

    // MARK: Storage layout

    private static let fileName = "trusted-peers.json"

    private struct Envelope: Codable {
        var version: Int
        var peers: [TrustedPeer]
    }

    // MARK: Properties

    private let directory: URL
    private let lock = NSLock()

    // MARK: Init

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Public API

    /// Adds a new trusted peer. Throws `.duplicateFingerprint` if a peer with
    /// the same public-key fingerprint is already stored.
    public func add(_ peer: TrustedPeer) throws {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try _load()
        let fingerprint = peer.fingerprint
        guard !envelope.peers.contains(where: { $0.fingerprint == fingerprint }) else {
            throw Error.duplicateFingerprint
        }
        envelope.peers.append(peer)
        try _save(envelope)
    }

    /// Removes the peer with the given ID. Throws `.notFound` if absent.
    public func remove(id: RemoteDeviceID) throws {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try _load()
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
        var envelope = try _load()
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
        let envelope = try _load()
        return envelope.peers.first(where: { $0.id == id })
    }

    /// Returns `true` if any stored peer has the given fingerprint.
    public func contains(fingerprint: RemoteIdentityFingerprint) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let envelope = try _load()
        return envelope.peers.contains(where: { $0.fingerprint == fingerprint })
    }

    /// Returns the peer whose `publicKey`'s fingerprint matches the
    /// provided fingerprint, or `nil` if no peer has been paired with
    /// that key. Mirrors `PinnedHostStore.get(fingerprint:)` on the
    /// client side.
    public func get(fingerprint: RemoteIdentityFingerprint) throws -> TrustedPeer? {
        lock.lock()
        defer { lock.unlock() }
        let envelope = try _load()
        return envelope.peers.first(where: { $0.fingerprint == fingerprint })
    }

    /// Returns all peers, sorted by `lastSeenAt` descending (most recently
    /// seen first), with `pairedAt` descending as a tiebreak for peers that
    /// have never been seen (nil `lastSeenAt`).
    public func list() throws -> [TrustedPeer] {
        lock.lock()
        defer { lock.unlock() }
        let envelope = try _load()
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }

    // MARK: Private helpers (call only while holding `lock`)

    private func _load() throws -> Envelope {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return Envelope(version: RemoteAccessProtocol.version,peers: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.version == RemoteAccessProtocol.version else {
                return Envelope(version: RemoteAccessProtocol.version, peers: [])
            }
            return envelope
        } catch {
            // Corrupt file: back it up and return an empty envelope so callers can recover.
            // Best effort: if the rename fails (permissions, etc.) we still return empty
            // so operations like revocation remain possible after corruption.
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            let backupURL = directory.appendingPathComponent("\(Self.fileName).corrupt.\(ms)")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return Envelope(version: RemoteAccessProtocol.version,peers: [])
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
