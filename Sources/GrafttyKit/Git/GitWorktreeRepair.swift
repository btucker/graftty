import Foundation

/// Runs `git worktree repair [<path>...]` in a repository to fix the
/// `gitdir:` pointers in linked worktrees whose on-disk paths have
/// changed externally (e.g. after a Finder rename of the main repo
/// folder, or a relocate cascade that moves `.worktrees/<name>`).
///
/// Shape parallels `GitWorktreeRemove` — a thin wrapper over
/// `GitRunner.captureAll` that translates a non-zero exit into a typed
/// `gitFailed` error so callers can surface or log git's stderr.
public enum GitWorktreeRepair {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
    }

    /// - Parameters:
    ///   - repoPath: the repository root (main checkout). The command
    ///     is run from here; `git worktree repair` with no path args
    ///     walks the repo's registered linked worktrees and fixes any
    ///     whose `gitdir:` file points to a stale location.
    ///   - worktreePaths: optional list of explicit worktree paths to
    ///     repair. When provided, only those worktrees are touched —
    ///     useful when a relocate cascade already knows exactly which
    ///     worktrees moved and wants to avoid a full walk. Defaults to
    ///     empty, which mirrors `git worktree repair` with no args.
    public static func repair(repoPath: String, worktreePaths: [String] = []) async throws {
        var args = ["worktree", "repair"]
        args.append(contentsOf: worktreePaths)
        let result = try await GitRunner.captureAll(args: args, at: repoPath)
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
