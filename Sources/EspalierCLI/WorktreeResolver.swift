import Foundation
import EspalierKit

enum WorktreeResolver {
    /// Resolve the current working directory to a worktree path tracked by
    /// Espalier. Throws `.notInsideWorktree` if either (a) PWD isn't inside
    /// any git repo or worktree, or (b) the resolved worktree isn't tracked
    /// by the running Espalier app.
    ///
    /// "Tracked" is determined by reading the persisted `state.json` — if
    /// the resolved path matches any `WorktreeEntry.path` in any repo, it's
    /// tracked. Otherwise it isn't. This implements ATTN-3.2: the old
    /// behavior only checked "inside a git worktree" but the spec error
    /// message says "tracked", which is a stronger guarantee.
    static func resolve() throws -> String {
        let pwd = FileManager.default.currentDirectoryPath
        let result = try GitRepoDetector.detect(path: pwd)
        let candidate: String
        switch result {
        case .repoRoot(let path): candidate = path
        case .worktree(let worktreePath, _): candidate = worktreePath
        case .notARepo: throw CLIError.notInsideWorktree
        }

        guard Self.isTracked(path: candidate) else {
            throw CLIError.notInsideWorktree
        }
        return candidate
    }

    /// Check whether `path` matches a worktree entry persisted in
    /// `state.json`. Separated out for testability.
    static func isTracked(
        path: String,
        stateDirectory: URL = AppState.defaultDirectory
    ) -> Bool {
        guard let state = try? AppState.load(from: stateDirectory) else {
            return false
        }
        return state.worktree(forPath: path) != nil
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notInsideWorktree
    case appNotRunning
    case staleControlSocket(path: String)
    case socketTimeout
    case socketError(String)
    case socketPathTooLong(bytes: Int, maxBytes: Int)

    var description: String {
        switch self {
        case .notInsideWorktree: return "Not inside a tracked worktree"
        case .appNotRunning: return "Espalier is not running"
        case .staleControlSocket(let path):
            return "Espalier is running but not listening on \(path). Quit and relaunch Espalier to reset the control socket."
        case .socketTimeout: return "Connection timed out after 2 seconds"
        case .socketError(let msg): return "Socket error: \(msg)"
        case .socketPathTooLong(let bytes, let maxBytes):
            return "Socket path is \(bytes) bytes, exceeds macOS sockaddr_un limit of \(maxBytes). Set ESPALIER_SOCK to a shorter path."
        }
    }
}
