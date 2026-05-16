import CryptoKit
import Foundation
import GrafttyProtocol

// MARK: - HostIdentityStore

/// @spec REMOTE-1.1
/// Persists the host's long-lived X25519 identity keypair.
///
/// The private key is stored as its 32-byte raw representation in a JSON
/// file (`host-identity.json`) inside the given directory. The store is
/// safe to use from concurrent contexts because all mutations are
/// serialised through an `NSLock`.
public final class HostIdentityStore: @unchecked Sendable {

    // MARK: Storage layout

    private static let fileName = "host-identity.json"

    /// Encodes/decodes the raw private-key bytes to/from JSON.
    private struct StoredKey: Codable {
        /// Base64-encoded 32-byte raw representation of the private key.
        let privateKeyData: Data
    }

    // MARK: Properties

    private let directory: URL
    private let lock = NSLock()

    // MARK: Init

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Public API

    /// Loads the persisted private key, returning `nil` if no key has been
    /// stored yet.
    public func load() throws -> Curve25519.KeyAgreement.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return try _load()
    }

    /// Generates a fresh X25519 private key, persists it, and returns it.
    /// Any previously persisted key is overwritten.
    public func generateAndPersist() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try _persist(key)
        return key
    }

    /// Returns the currently stored key, or generates and persists a new one
    /// if no key exists yet. Suitable for app-boot time.
    public func loadOrGenerateAndPersist() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let existing = try _load() {
            return existing
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try _persist(key)
        return key
    }

    /// Deletes the persisted key. A subsequent `load()` will return `nil`.
    /// Use this to rotate the host identity.
    public func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = directory.appendingPathComponent(Self.fileName)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone — treat as success.
        }
    }

    /// Derives the `RemoteIdentityPublicKey` from the currently stored private
    /// key. Returns `nil` if no key has been persisted yet.
    public func currentPublicKey() throws -> RemoteIdentityPublicKey? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = try _load() else { return nil }
        return try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    // MARK: Default directory

    /// The production default storage directory.
    // TODO: Keychain integration before v1 production release —
    // the private key should be stored in the Keychain/Secure Enclave
    // rather than Application Support. This file-backed path is used
    // until that integration lands.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }

    // MARK: Private helpers (call only while holding `lock`)

    private func _load() throws -> Curve25519.KeyAgreement.PrivateKey? {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode(StoredKey.self, from: data)
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored.privateKeyData)
        } catch {
            // Corrupt file: back it up and signal "no key" so callers can recover.
            // Best effort: if the rename fails (permissions, etc.) we still return nil
            // so the app boots. The next persist will overwrite the corrupt file.
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            let backupURL = directory.appendingPathComponent("\(Self.fileName).corrupt.\(ms)")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            return nil
        }
    }

    private func _persist(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let stored = StoredKey(privateKeyData: key.rawRepresentation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stored)
        try data.write(to: fileURL, options: .atomic)
        // Restrict to owner-read/write only — this file holds the raw private key.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }
}
