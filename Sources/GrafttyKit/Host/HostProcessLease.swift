import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One runtime or offline administration operation may own state at a time.
/// Kernel release on process exit allows restart without stale PID-file logic.
public final class HostProcessLease {
    private let descriptor: Int32
    public init(configuration: HostConfiguration) throws {
        try configuration.prepareDirectories()
        let path = configuration.stateDirectory.appendingPathComponent("host.lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw HostRuntimeError.invalid("cannot open host process lock") }
        guard lockf(descriptor, F_TLOCK, 0) == 0 else {
            close(descriptor)
            throw HostRuntimeError.busy("host is running; use its local administration socket")
        }
    }
    deinit { _ = lockf(descriptor, F_ULOCK, 0); close(descriptor) }
}
