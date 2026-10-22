import Foundation

/// @spec PERSIST-5.4
/// The application shall encode a JSONFileStore's dates and output
/// formatting exactly as the store is configured, so a migrated store keeps
/// the byte format its earlier releases wrote.
///
/// One `Codable` value persisted as JSON at a fixed file URL.
///
/// Every policy that decides the on-disk bytes or failure behaviour — date
/// encoding, output formatting, parent-directory creation, file permissions,
/// corrupt-file backup naming — is an explicit option, because each store
/// built on this type must keep writing what its earlier releases wrote.
/// The defaults match a bare `JSONEncoder()` / `JSONDecoder()` pair.
///
/// The store holds no state and no lock; callers that need serialised
/// read-modify-write cycles provide their own.
public struct JSONFileStore<Value: Codable>: Sendable {

    public enum DateCoding: Sendable {
        /// Foundation's default: seconds since the reference date, as a number.
        case deferredToDate
        /// ISO 8601 strings (`JSONEncoder.iso8601()`).
        case iso8601
    }

    /// How `moveAsideCorruptFile` names the backup beside the original.
    public enum CorruptBackupNaming: Sendable {
        /// `<name>.corrupt.<milliseconds-since-epoch>`.
        case dotMilliseconds
        /// `<name>.corrupt-<seconds-since-epoch>`.
        case dashSeconds
    }

    public let fileURL: URL
    private let dates: DateCoding
    private let outputFormatting: JSONEncoder.OutputFormatting
    private let createsDirectory: Bool
    private let posixPermissions: Int16?
    private let backupNaming: CorruptBackupNaming

    public init(
        fileURL: URL,
        dates: DateCoding = .deferredToDate,
        outputFormatting: JSONEncoder.OutputFormatting = [],
        createsDirectory: Bool = true,
        posixPermissions: Int16? = nil,
        backupNaming: CorruptBackupNaming = .dotMilliseconds
    ) {
        self.fileURL = fileURL
        self.dates = dates
        self.outputFormatting = outputFormatting
        self.createsDirectory = createsDirectory
        self.posixPermissions = posixPermissions
        self.backupNaming = backupNaming
    }

    /// Returns `nil` when the file does not exist. Read failures rethrow as
    /// the underlying file error; malformed contents throw `DecodingError`,
    /// so callers can tell corruption apart from an unreadable file.
    public func load() throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try decode(data)
    }

    /// Loads the value, or `nil` when the file is missing, unreadable or
    /// malformed. Malformed contents are first moved aside (best effort) so
    /// the caller's next save cannot destroy the user's prior data.
    public func loadMovingAsideCorruptFile() -> Value? {
        do {
            return try load()
        } catch is DecodingError {
            moveAsideCorruptFile()
            return nil
        } catch {
            return nil
        }
    }

    /// Every decode failure throws `DecodingError`, including errors a
    /// value's own `init(from:)` throws, so callers' corruption handling
    /// covers field validation too (PERSIST-5.7).
    public func decode(_ data: Data) throws -> Value {
        let decoder: JSONDecoder
        switch dates {
        case .deferredToDate: decoder = JSONDecoder()
        case .iso8601: decoder = .iso8601()
        }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Rejected while decoding: \(error)",
                underlyingError: error
            ))
        }
    }

    public func encode(_ value: Value) throws -> Data {
        let encoder: JSONEncoder
        switch dates {
        case .deferredToDate: encoder = JSONEncoder()
        case .iso8601: encoder = .iso8601()
        }
        encoder.outputFormatting = outputFormatting
        return try encoder.encode(value)
    }

    public func save(_ value: Value) throws {
        try write(encode(value))
    }

    /// Atomically replaces the file with already-encoded bytes, for callers
    /// that validate the encoding (e.g. a size cap) before writing it.
    public func write(_ data: Data) throws {
        if createsDirectory {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try data.write(to: fileURL, options: .atomic)
        if let posixPermissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: posixPermissions)],
                ofItemAtPath: fileURL.path
            )
        }
    }

    /// Deletes the file; a file that is already gone is not an error.
    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone.
        }
    }

    /// Best-effort rename of an unreadable file so the user's prior data
    /// survives the fresh value the caller is about to write. Returns the
    /// backup URL, or `nil` when the rename failed.
    @discardableResult
    public func moveAsideCorruptFile(now: Date = Date()) -> URL? {
        let name = fileURL.lastPathComponent
        let suffix: String
        switch backupNaming {
        case .dotMilliseconds: suffix = ".corrupt.\(Int(now.timeIntervalSince1970 * 1000))"
        case .dashSeconds: suffix = ".corrupt-\(Int(now.timeIntervalSince1970))"
        }
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(name + suffix)
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }
}
