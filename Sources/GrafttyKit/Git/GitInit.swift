import Foundation

/// Initializes a git repository at `path` with an empty initial commit.
///
/// Runs `git init` followed by `git commit --allow-empty -m "Initial commit"`.
/// The empty commit gives the repo a real branch on whatever
/// `init.defaultBranch` is configured (`main` on modern installs), so the
/// subsequent `git worktree list --porcelain` produced by the Add Repository
/// flow returns a named branch rather than a detached/unborn HEAD.
///
/// Errors mirror `GitWorktreeAdd`: non-zero exit becomes
/// `Error.gitFailed(exitCode:stderr:)` so callers can show git's stderr in
/// an `NSAlert`; launch / not-found problems become `Error.cliFailure` so
/// callers can distinguish "git ran and rejected" from "git never ran".
///
/// The `git commit` invocation is prefixed with ephemeral
/// `-c user.name` / `-c user.email` config so that the empty initial commit
/// still succeeds on systems where the user has no global git identity
/// configured (a common CI condition). The values are scoped to this single
/// invocation and don't touch the user's global or per-repo config.
public enum GitInit {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
        /// Git failed to launch or was not found on PATH.
        case cliFailure(CLIError)
    }

    /// - Parameter path: directory in which to run `git init`. Must already exist.
    public static func run(at path: String) async throws {
        try await runStep(args: ["init"], at: path)
        try await runStep(
            args: [
                "-c", "user.name=Graftty",
                "-c", "user.email=noreply@graftty.local",
                "commit", "--allow-empty", "-m", "Initial commit",
            ],
            at: path
        )
    }

    private static func runStep(args: [String], at path: String) async throws {
        let result: CLIOutput
        do {
            result = try await GitRunner.captureAll(args: args, at: path)
        } catch let err as CLIError {
            throw Error.cliFailure(err)
        }
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
