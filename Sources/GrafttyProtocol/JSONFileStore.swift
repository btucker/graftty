import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// @spec PERSIST-5.4
/// The application shall encode a JSONFileStore's dates and output
/// formatting exactly as the store is configured, so a migrated store keeps
/// the byte format its earlier releases wrote.
///
/// @spec PERSIST-5.20
/// When a JSONFileStore publishes a file, the application shall synchronize its
/// contents and then fsync the containing directory once before returning
/// success, propagating synchronization failures.
///
/// One `Codable` value persisted as JSON at a fixed file URL.
///
/// Writes provide fsync-level durability for the file and its immediate parent
/// directory on Darwin and Linux filesystems that support directory fsync.
/// Newly created ancestor directories are not synchronized. Darwin drive-cache
/// flushing via F_FULLFSYNC is outside this guarantee.
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
    private let readData: @Sendable (URL) throws -> Data
    var moveItem: @Sendable (URL, URL) throws -> Void = {
        try FileManager.default.moveItem(at: $0, to: $1)
    }

    public init(
        fileURL: URL,
        dates: DateCoding = .deferredToDate,
        outputFormatting: JSONEncoder.OutputFormatting = [],
        createsDirectory: Bool = true,
        posixPermissions: Int16? = nil,
        backupNaming: CorruptBackupNaming = .dotMilliseconds,
        readData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.fileURL = fileURL
        self.dates = dates
        self.outputFormatting = outputFormatting
        self.createsDirectory = createsDirectory
        self.posixPermissions = posixPermissions
        self.backupNaming = backupNaming
        self.readData = readData
    }

    /// Returns `nil` when the file does not exist. Read failures rethrow as
    /// the underlying file error; malformed contents throw `DecodingError`,
    /// so callers can tell corruption apart from an unreadable file.
    public func load() throws -> Value? {
        try load(readData: readData)
    }

    func load(readData: (URL) throws -> Data) throws -> Value? {
        let data: Data
        do {
            data = try readData(fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try decode(data)
    }

    /// Loads the value, or `nil` when the file is missing or malformed.
    /// Malformed contents are first moved aside. Read and backup failures
    /// throw so a caller cannot replace data it has not loaded or preserved.
    public func loadMovingAsideCorruptFile() throws -> Value? {
        do {
            return try load()
        } catch is DecodingError {
            try moveAsideCorruptFile()
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
    /// A synchronization failure after publication throws even though the new
    /// file is already visible at the destination.
    public func write(_ data: Data) throws {
        try write(data, beforeReplacing: { _ in })
    }

    func write(
        _ data: Data,
        beforeReplacing: (URL) throws -> Void,
        synchronizeDirectory: (Int32) -> Int32 = { fsync($0) }
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        if createsDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
        if let posixPermissions {
            try writeRestricted(data, permissions: posixPermissions, beforeReplacing: beforeReplacing)
        } else {
            // Foundation synchronizes the file contents during its atomic write.
            try data.write(to: fileURL, options: .atomic)
        }

        // File synchronization alone does not persist rename's directory entry.
        // Publish first, then synchronize this directory exactly once.
        let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(directoryDescriptor) }
        guard synchronizeDirectory(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeRestricted(
        _ data: Data,
        permissions posixPermissions: Int16,
        beforeReplacing: (URL) throws -> Void
    ) throws {
        // mkstemp creates the file as 0600 before any secret bytes are written.
        // Keep it beside the destination so rename is an atomic replacement.
        var template = Array(fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporaryURL = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard fchmod(descriptor, mode_t(UInt16(bitPattern: posixPermissions))) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try beforeReplacing(temporaryURL)
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

    /// Renames a corrupt file so the user's prior data survives replacement.
    /// A failed rename throws and leaves the original and any prior backup intact.
    @discardableResult
    public func moveAsideCorruptFile(now: Date = Date()) throws -> URL {
        let name = fileURL.lastPathComponent
        let suffix: String
        switch backupNaming {
        case .dotMilliseconds: suffix = ".corrupt.\(Int(now.timeIntervalSince1970 * 1000))"
        case .dashSeconds: suffix = ".corrupt-\(Int(now.timeIntervalSince1970))"
        }
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(name + suffix)
        try moveItem(fileURL, backupURL)
        return backupURL
    }
}
