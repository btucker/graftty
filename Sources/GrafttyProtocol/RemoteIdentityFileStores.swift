#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Shares transaction locks across store instances without retaining unused paths.
private final class RemoteIdentityFileLocks: @unchecked Sendable {
    static let shared = RemoteIdentityFileLocks()

    private struct Entry {
        weak var lock: NSLock?
    }

    private let registryLock = NSLock()
    private var entries: [String: Entry] = [:]

    func lock(for fileURL: URL) -> NSLock {
        // Atomic writes replace the leaf itself, so never follow its symlink.
        // Resolve the nearest existing parent even before first-run directories
        // exist; Foundation does not resolve aliases through a missing leaf.
        var directory = fileURL.deletingLastPathComponent().standardizedFileURL
        var components = [fileURL.lastPathComponent]
        while directory.path != "/", !FileManager.default.fileExists(atPath: directory.path) {
            components.append(directory.lastPathComponent)
            directory.deleteLastPathComponent()
        }
        let canonicalDirectory = directory.resolvingSymlinksInPath()
        let path = components.reversed().reduce(canonicalDirectory) { $0.appendingPathComponent($1) }.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = entries[path]?.lock { return existing }
        entries = entries.filter { $0.value.lock != nil }
        let lock = NSLock()
        entries[path] = Entry(lock: lock)
        return lock
    }
}

// MARK: - RemoteIdentityFileLocation

/// Names one role's remote-identity file: host vs client, key vs device ID.
/// Conformers are caseless enums; the stores below are specialised on them
/// (`HostIdentityStore = RemoteIdentityKeyStore<HostIdentityFile>`), so each
/// role keeps its own type, file name, and production directory.
public protocol RemoteIdentityFileLocation {
    static var fileName: String { get }
    /// The production default storage directory.
    static var defaultDirectory: URL { get }
}

extension RemoteIdentityFileLocation {
    /// `Application Support/Graftty/Remote`, shared by the remote-identity
    /// stores that do not override it.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }
}

// MARK: - RemoteIdentityKeyStore

/// Persists a long-lived Ed25519 identity keypair for one role.
///
/// The private key is stored as its 32-byte raw representation in a JSON
/// file (`Location.fileName`, owner-only 0600) inside the given directory,
/// alongside a schema version. Every access in this process is serialised
/// through an `NSLock` shared by the canonical file path. A file from another
/// schema version, or whose bytes are not a valid key, is moved aside to
/// `<name>.corrupt-<seconds>`; other read failures throw.
public final class RemoteIdentityKeyStore<Location: RemoteIdentityFileLocation>: @unchecked Sendable {

    /// Encodes/decodes the raw private-key bytes to/from JSON, plus a
    /// schema version so legacy formats are detected and rejected by the
    /// corruption-recovery path.
    private struct StoredKey: Codable {
        let version: Int
        let privateKeyData: Data
    }

    private static var currentVersion: Int { 2 }

    private let file: JSONFileStore<StoredKey>
    private let readData: @Sendable (URL) throws -> Data
    let lock: NSLock

    public convenience init(directory: URL) {
        self.init(directory: directory, readData: { try Data(contentsOf: $0) })
    }

    init(
        directory: URL,
        readData: @escaping @Sendable (URL) throws -> Data,
        moveCorruptFile: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    ) {
        self.readData = readData
        let fileURL = directory.appendingPathComponent(Location.fileName)
        lock = RemoteIdentityFileLocks.shared.lock(for: fileURL)
        var file = JSONFileStore<StoredKey>(
            fileURL: fileURL,
            posixPermissions: 0o600,
            backupNaming: .dashSeconds
        )
        file.moveItem = moveCorruptFile
        self.file = file
    }

    public static var defaultDirectory: URL { Location.defaultDirectory }

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
        return try _generateAndPersist()
    }

    /// Returns the currently stored key, or generates and persists a new one
    /// if no key exists yet. Suitable for app-boot time.
    public func loadOrGenerateAndPersist() throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        return try _load() ?? _generateAndPersist()
    }

    /// Deletes the persisted key. A subsequent `load()` will return `nil`.
    public func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        try file.remove()
    }

    /// Returns the public key derived from the persisted private key, or
    /// `nil` if no key is stored.
    public func currentPublicKey() throws -> RemoteIdentityPublicKey? {
        guard let key = try load() else {
            return nil
        }
        return try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    // MARK: Private (call only while holding `lock`)

    private func _load() throws -> Curve25519.Signing.PrivateKey? {
        do {
            guard let stored = try file.load(readData: readData) else {
                return nil
            }
            guard stored.version == Self.currentVersion else {
                try file.moveAsideCorruptFile()
                return nil
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: stored.privateKeyData)
        } catch is DecodingError, is CryptoKitError {
            // Legacy schemas (no `version` field) decode-fail here; treat as corrupt.
            // CryptoKitError covers byte-level corruption inside a structurally valid record.
            try file.moveAsideCorruptFile()
            return nil
        }
    }

    private func _generateAndPersist() throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        try file.save(StoredKey(version: Self.currentVersion, privateKeyData: key.rawRepresentation))
        return key
    }
}

// MARK: - RemoteDeviceIDStore

/// Persists one role's stable `RemoteDeviceID` so pairing payloads and
/// peer records identify the same device across launches.
///
/// The ID is stored in a JSON file (`Location.fileName`) inside the given
/// directory, alongside a schema version. Every access in this process is
/// serialised through an `NSLock` shared by the canonical file path. Read
/// failures throw so a temporarily inaccessible identity is preserved; a
/// corrupt or foreign-schema file is first moved aside to
/// `<name>.corrupt-<seconds>` before generating a replacement.
public final class RemoteDeviceIDStore<Location: RemoteIdentityFileLocation>: @unchecked Sendable {

    private struct StoredID: Codable {
        let version: Int
        let deviceID: RemoteDeviceID
    }

    private static var currentVersion: Int { 1 }

    private let file: JSONFileStore<StoredID>
    private let readData: @Sendable (URL) throws -> Data
    let lock: NSLock

    public convenience init(directory: URL) {
        self.init(directory: directory, readData: { try Data(contentsOf: $0) })
    }

    init(
        directory: URL,
        readData: @escaping @Sendable (URL) throws -> Data,
        moveCorruptFile: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    ) {
        self.readData = readData
        let fileURL = directory.appendingPathComponent(Location.fileName)
        lock = RemoteIdentityFileLocks.shared.lock(for: fileURL)
        var file = JSONFileStore<StoredID>(
            fileURL: fileURL,
            backupNaming: .dashSeconds
        )
        file.moveItem = moveCorruptFile
        self.file = file
    }

    public static var defaultDirectory: URL { Location.defaultDirectory }

    /// Loads the persisted `RemoteDeviceID`, or generates + persists one.
    public func loadOrGenerateAndPersist() throws -> RemoteDeviceID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = try _load() {
            return existing
        }
        let id = RemoteDeviceID.generate()
        try file.save(StoredID(version: Self.currentVersion, deviceID: id))
        return id
    }

    // MARK: Private (call only while holding `lock`)

    private func _load() throws -> RemoteDeviceID? {
        do {
            guard let stored = try file.load(readData: readData) else {
                return nil
            }
            guard stored.version == Self.currentVersion, !stored.deviceID.value.isEmpty else {
                try file.moveAsideCorruptFile()
                return nil
            }
            return stored.deviceID
        } catch is DecodingError {
            try file.moveAsideCorruptFile()
            return nil
        }
    }
}
