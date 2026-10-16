import Foundation
import GrafttyProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads regular files without decoding or restricting Quick Look's supported types.
public enum FilePreviewLoader {
    public static let maximumFiles = 20
    public static let maximumTotalBytes = 50 * 1024 * 1024

    public struct Snapshot: Sendable {
        public let filename: String
        public let bytes: Data
        public init(filename: String, bytes: Data) { self.filename = filename; self.bytes = bytes }
    }

    public enum Failure: LocalizedError {
        case unreadable, tooLarge, invalidCollection
        public var errorDescription: String? {
            switch self {
            case .unreadable: "Choose readable regular files."
            case .tooLarge: "Previews are limited to 20 MB per file and 50 MB total."
            case .invalidCollection: "Choose between 1 and 20 files to preview."
            }
        }
    }

    public static func snapshots(_ urls: [URL]) throws -> [Snapshot] {
        guard (1...maximumFiles).contains(urls.count) else { throw Failure.invalidCollection }
        var total = 0
        return try urls.map { url in
            let snapshot = try snapshot(url)
            total += snapshot.bytes.count
            guard total <= maximumTotalBytes else { throw Failure.tooLarge }
            return snapshot
        }
    }

    /// Shares the bounded, nonblocking regular-file read with graftty open.
    public static func snapshot(_ url: URL) throws -> Snapshot {
        guard url.isFileURL else { throw Failure.unreadable }
        let fd = GrafttyPOSIX.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unreadable }
        guard info.st_size <= RemoteOpenOffer.maxBytes else { throw Failure.tooLarge }
        let bytes = try handle.read(upToCount: RemoteOpenOffer.maxBytes + 1) ?? Data()
        guard bytes.count <= RemoteOpenOffer.maxBytes else { throw Failure.tooLarge }
        return Snapshot(filename: url.lastPathComponent, bytes: bytes)
    }
}
