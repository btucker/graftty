import Foundation

/// Removes a git worktree, deleting its directory on disk and pruning the
/// repo's `.git/worktrees/<name>` administrative entry. The branch the
/// worktree had checked out is left intact — `git worktree remove` does
/// not touch refs.
///
/// Delegates to `git worktree remove <path>`. Reports git's stderr on
/// failure so callers can surface the user-visible error (e.g. "contains
/// modified or untracked files, use --force to delete it").
public enum GitWorktreeRemove {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
    }

    /// - Parameters:
    ///   - repoPath: the repository root (the main checkout directory).
    ///     The command is run from here so git resolves the worktree
    ///     administrative entry correctly.
    ///   - worktreePath: the linked worktree to remove. Must not be the
    ///     main checkout — git refuses that.
    ///   - force: when `true`, pass `--force` so git deletes the worktree
    ///     even if it has uncommitted/untracked changes. Used by the
    ///     "Force Delete" branch of the failure dialog (GIT-4.12).
    public static func remove(
        repoPath: String,
        worktreePath: String,
        force: Bool = false
    ) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        let result = try await GitRunner.captureAll(
            args: args,
            at: repoPath
        )
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// The Git side of removing a tracked worktree, shared by the Mac app's
    /// `DeleteWorktreeFlow` and the headless host. GIT-4.13: when the
    /// directory has already vanished but its admin entry survives,
    /// `--force` cannot bypass Git's path validation, so prune instead and
    /// report a dismissal. A refusal without `--force` carries
    /// `git status --short` so the caller can offer a forced retry.
    public static func removeOrPrune(
        repoPath: String,
        worktreePath: String,
        force: Bool
    ) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError> {
        do {
            try await remove(repoPath: repoPath, worktreePath: worktreePath, force: force)
            return .success(WorktreeRemovalOutcome(dismissed: false))
        } catch Error.gitFailed(_, let stderr) {
            if !FileManager.default.fileExists(atPath: worktreePath) {
                try? await GitWorktreePrune.run(repoPath: repoPath)
                return .success(WorktreeRemovalOutcome(dismissed: true))
            }
            if force {
                return .failure(.gitFailedFinal(stderr.isEmpty ? "git worktree remove --force failed" : stderr))
            }
            return .failure(.gitFailedForceable(
                stderr: stderr.isEmpty ? "git worktree remove failed" : stderr,
                shortStatus: await GitStatusCapture.shortStatus(at: worktreePath)
            ))
        } catch {
            return .failure(.gitFailedFinal("\(error)"))
        }
    }
}
