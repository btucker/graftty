import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Holds an advisory lock across processes and separate store instances.
/// Keep the object alive for the whole read/modify/write transaction.
final class ExclusiveFileLock: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL, wait: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
    }

    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}
