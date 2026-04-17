import Foundation

/// Creates a new git worktree for a repository with a fresh branch.
///
/// Delegates to `git worktree add -b <branch> <path> [<start>]`. Reports
/// git's stderr on failure so callers can surface the user-visible error
/// (e.g. "branch 'foo' already exists").
public enum GitWorktreeAdd {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
    }

    /// - Parameters:
    ///   - repoPath: the repository root (the main checkout directory).
    ///   - worktreePath: where to create the new worktree on disk. May be
    ///     absolute or relative to `repoPath`.
    ///   - branchName: the new branch to create. Passed as `-b <branch>`,
    ///     so this must not already exist as a local branch.
    ///   - startPoint: ref to branch from (e.g. `"main"`,
    ///     `"origin/main"`). Nil defers to git's default (current HEAD
    ///     of the main checkout).
    public static func add(
        repoPath: String,
        worktreePath: String,
        branchName: String,
        startPoint: String?
    ) throws {
        var args: [String] = ["worktree", "add", "-b", branchName, worktreePath]
        if let startPoint, !startPoint.isEmpty {
            args.append(startPoint)
        }
        let result = try GitRunner.captureAll(args: args, at: repoPath)
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
