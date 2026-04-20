import Foundation
import Darwin

/// Classifies why a `connect()` to the Espalier control socket failed.
/// ATTN-3.4: distinguishing "socket file is missing" from "socket file
/// exists but nothing is listening" lets the CLI tell the user what to
/// actually do — a stale file means Espalier is running with a broken
/// socket and needs to be relaunched, whereas a missing file means the
/// app isn't up at all.
public enum ControlSocketDiagnosis {

    public enum Reason: Equatable, Sendable {
        case notRunning
        case staleSocket(path: String)
        case timeout
    }

    public static func classifyConnectFailure(
        errno: Int32,
        socketExists: Bool,
        path: String
    ) -> Reason {
        if errno == ECONNREFUSED && socketExists {
            return .staleSocket(path: path)
        }
        if errno == ECONNREFUSED || errno == ENOENT {
            return .notRunning
        }
        return .timeout
    }
}
