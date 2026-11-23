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
        var sawDenied = false
        for path in probePaths {
            switch openFile(path) {
            case .opened:
                return .granted
            case .failed(let code) where code == EPERM || code == EACCES:
                sawDenied = true
            case .failed:
                continue
            }
        }
        return sawDenied ? .denied : .unknown
    }

    static func defaultOpenFile(_ path: String) -> ProbeOutcome {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            Darwin.close(fd)
            return .opened
        }
        return .failed(errno)
    }
}
