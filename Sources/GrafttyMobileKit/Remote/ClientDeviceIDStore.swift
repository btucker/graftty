#if canImport(UIKit)
import Foundation
import GrafttyProtocol

// MARK: - ClientDeviceIDStore

/// Persists the client's stable `RemoteDeviceID` so pairing requests and
/// pinned-host records identify the same device across launches.
///
/// Mirrors the host-side `HostDeviceIDStore` idiom exactly (separate module,
/// intentional duplication — see `HostDeviceIDStore` for rationale). The ID
/// is stored in a JSON file (`client-device-id.json`) inside the given
/// directory, alongside a schema version. Safe to use from concurrent
/// contexts: all access is serialised through an `NSLock`.
public final class ClientDeviceIDStore: @unchecked Sendable {

    // MARK: Storage layout

    private static let fileName = "client-device-id.json"
    private static let currentVersion = 1

    private struct StoredID: Codable {
        let version: Int
        let deviceID: RemoteDeviceID
    }

    // MARK: Properties

    private let directory: URL
    private let lock = NSLock()

    // MARK: Init

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Public API

    /// Loads the persisted `RemoteDeviceID`, or generates + persists one.
    /// A corrupt or foreign-schema file is backed up and replaced with a
    /// freshly generated ID so the client always has a usable identity.
    public func loadOrGenerateAndPersist() throws -> RemoteDeviceID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _load() {
            return existing
        }
        let id = RemoteDeviceID.generate()
        try _persist(id)
        return id
    }

    // MARK: Default directory

    /// The production default storage directory (shared with the other
    /// remote-identity stores).
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }

    // MARK: Private (call only while holding `lock`)

    private func _load() -> RemoteDeviceID? {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        do {
            let stored = try JSONDecoder().decode(StoredID.self, from: data)
            guard stored.version == Self.currentVersion, !stored.deviceID.value.isEmpty else {
                backupCorruptFile(at: fileURL)
                return nil
            }
            return stored.deviceID
        } catch {
            backupCorruptFile(at: fileURL)
            return nil
        }
    }

    private func _persist(_ id: RemoteDeviceID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let stored = StoredID(version: Self.currentVersion, deviceID: id)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: .atomic)
    }

    private func backupCorruptFile(at fileURL: URL) {
        let backupURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }
}
#endif
