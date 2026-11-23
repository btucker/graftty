import Darwin
import Foundation

enum FullDiskAccessStatus: Equatable, Sendable {
    case granted
    case denied
    case unknown
}

/// Probes macOS Full Disk Access (`kTCCServiceSystemPolicyAllFiles`) by
/// attempting read-only POSIX `open()` calls against TCC-protected files that
/// never trigger per-folder system consent alerts.
enum FullDiskAccess {
    enum ProbeOutcome: Equatable, Sendable {
        case opened
        case failed(Int32)
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    static func defaultProbePaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        [
            homeDirectory
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
                .path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ]
    }

    static func checkStatus(
        probePaths: [String] = defaultProbePaths(),
        openFile: (String) -> ProbeOutcome = defaultOpenFile
    ) -> FullDiskAccessStatus {
        for path in probePaths {
            switch openFile(path) {
            case .opened:
                return .granted
            case .failed(let code) where code == EPERM:
                // macOS MACF/TCC rejects SystemPolicyAllFiles opens with EPERM.
                // Stop immediately so a weaker fallback path cannot override an
                // authoritative TCC denial; POSIX EACCES/ENOENT fall through.
                return .denied
            case .failed:
                continue
            }
        }
        return .unknown
    }

    static func defaultOpenFile(_ path: String) -> ProbeOutcome {
        path.withCString { cPath in
            while true {
                let fd = Darwin.open(cPath, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
                if fd >= 0 {
                    Darwin.close(fd)
                    return .opened
                }
                let code = errno
                if code == EINTR { continue }
                return .failed(code)
            }
        }
    }
}
