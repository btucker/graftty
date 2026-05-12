import Foundation

/// Prunes stale `.git/worktrees/<name>` administrative entries whose
/// working-tree directories no longer exist on disk. Used by the
/// GIT-4.13 recovery path in `performDeleteWorktree` when
/// `git worktree remove` fails because the worktree directory is gone
/// (typical when agent tooling tears down scratch worktrees without
/// calling `git worktree remove` first).
///
/// `--expire=now` is required: a bare `git worktree prune` honors
/// `gc.worktreePruneExpire` (default 3 months) and would no-op on
/// recently-orphaned entries.
///
/// `prune` operates on the whole repo, not a single path — every
/// stale entry in the repo is pruned by one invocation. That matches
/// GIT-4.13's UX intent (the user wanted the dead row gone; other
/// dead rows in the same repo are also dead and should disappear).
public enum GitWorktreePrune {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
    }

    public static func run(repoPath: String) async throws {
        let result = try await GitRunner.captureAll(
            args: ["worktree", "prune", "--expire=now"],
            at: repoPath
        )
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
