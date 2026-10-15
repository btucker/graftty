import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Classifies why a `connect()` to the Graftty control socket failed.
/// ATTN-3.4: distinguishing "socket file is missing" from "socket file
/// exists but nothing is listening" lets the CLI tell the user what to
/// actually do — a stale file means Graftty is running with a broken
/// socket and needs to be relaunched, whereas a missing file means the
/// app isn't up at all.
public enum ControlSocketDiagnosis {

    public enum Reason: Equatable, Sendable {
        case notRunning
        case staleSocket(path: String)
        case busy
        case timeout
        case permissionDenied(path: String, errno: Int32)
        case failure(errno: Int32)
    }

    public static func classifyConnectFailure(
        errno: Int32,
        socketExists: Bool,
        path: String
    ) -> Reason {
        if errno == EPERM || errno == EACCES {
            return .permissionDenied(path: path, errno: errno)
        }
        if errno == ECONNREFUSED && socketExists {
            return .staleSocket(path: path)
        }
        if errno == ECONNREFUSED || errno == ENOENT {
            return .notRunning
        }
        if errno == EAGAIN || errno == ENOBUFS {
            return .busy
        }
        if errno == ETIMEDOUT {
            return .timeout
        }
        return .failure(errno: errno)
    }
}
