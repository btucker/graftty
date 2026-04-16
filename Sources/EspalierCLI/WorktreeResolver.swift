import Foundation
import EspalierKit

enum WorktreeResolver {
    static func resolve() throws -> String {
        let pwd = FileManager.default.currentDirectoryPath
        let result = try GitRepoDetector.detect(path: pwd)
        switch result {
        case .repoRoot(let path): return path
        case .worktree(let worktreePath, _): return worktreePath
        case .notARepo: throw CLIError.notInsideWorktree
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notInsideWorktree
    case appNotRunning
    case socketTimeout
    case socketError(String)

    var description: String {
        switch self {
        case .notInsideWorktree: return "Not inside a tracked worktree"
        case .appNotRunning: return "Espalier is not running"
        case .socketTimeout: return "Connection timed out after 2 seconds"
        case .socketError(let msg): return "Socket error: \(msg)"
        }
    }
}
