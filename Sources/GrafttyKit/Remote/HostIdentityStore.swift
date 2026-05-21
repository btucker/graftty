import CryptoKit
import Foundation
import GrafttyProtocol

// MARK: - HostIdentityStore

/// @spec REMOTE-1.1
/// Persists the host's long-lived Ed25519 identity keypair.
///
/// The private key is stored as its 32-byte raw representation in a JSON
/// file (`host-identity.json`) inside the given directory, alongside a
/// schema version. The store is safe to use from concurrent contexts
/// because all mutations are serialised through an `NSLock`.
public final class HostIdentityStore: @unchecked Sendable {

    // MARK: Storage layout

    private static let fileName = "host-identity.json"
    private static let currentVersion = 2

    /// Encodes/decodes the raw private-key bytes to/from JSON, plus a
    /// schema version so legacy formats are detected and rejected by the
    /// corruption-recovery path.
    private struct StoredKey: Codable {
        let version: Int
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
    /// stored yet or the stored record is from a previous schema.
    public func load() throws -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return try _load()
    }

    /// Generates a fresh Ed25519 private key, persists it, and returns it.
    /// Any previously persisted key is overwritten.
    public func generateAndPersist() throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        let key = Curve25519.Signing.PrivateKey()
        try _persist(key)
        return key
    }

    /// Returns the currently stored key, or generates and persists a new one
    /// if no key exists yet. Suitable for app-boot time.
    public func loadOrGenerateAndPersist() throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let existing = try _load() {
            return existing
        }
        let key = Curve25519.Signing.PrivateKey()
        try _persist(key)
        return key
    }

    /// Deletes the persisted key. A subsequent `load()` will return `nil`.
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

    /// Returns the public key derived from the persisted private key, or
    /// `nil` if no key is stored.
    public func currentPublicKey() throws -> RemoteIdentityPublicKey? {
        guard let key = try load() else {
            return nil
        }
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

    // MARK: Private (call only while holding `lock`)

    private func _load() throws -> Curve25519.Signing.PrivateKey? {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let stored = try JSONDecoder().decode(StoredKey.self, from: data)
            guard stored.version == Self.currentVersion else {
                backupCorruptFile(at: fileURL)
                return nil
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: stored.privateKeyData)
        } catch is DecodingError, is CryptoKitError {
            // Legacy schemas (no `version` field) decode-fail here; treat as corrupt.
            // CryptoKitError covers byte-level corruption inside a structurally valid record.
            backupCorruptFile(at: fileURL)
            return nil
        }
    }

    private func _persist(_ key: Curve25519.Signing.PrivateKey) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let stored = StoredKey(version: Self.currentVersion, privateKeyData: key.rawRepresentation)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: [.atomic])
        // Restrict to owner-read/write only — this file holds the raw private key.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private func backupCorruptFile(at fileURL: URL) {
        let backupURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }
}
