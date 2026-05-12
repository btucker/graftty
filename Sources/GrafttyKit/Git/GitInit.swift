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
/// If — and only if — the user has no effective git identity (no
/// `user.name`/`user.email` configured at the system/global level), the
/// `git commit` invocation is prefixed with ephemeral `-c user.name` /
/// `-c user.email` config so the empty initial commit still succeeds (a
/// common CI condition). When the user has a configured identity, the
/// commit runs without override so the initial commit is authored as the
/// user. The override values are scoped to this single invocation and
/// don't touch the user's global or per-repo config.
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

        // `git init` ran moments earlier, so the local repo has no config
        // yet — `git config user.email` therefore queries effective
        // (system/global) identity. Only inject the ephemeral fallback
        // when the user has no configured identity; otherwise the
        // `-c key=value` overrides would clobber the user's real name.
        let commitArgs: [String]
        if await hasConfiguredIdentity(at: path) {
            commitArgs = ["commit", "--allow-empty", "-m", "Initial commit"]
        } else {
            commitArgs = [
                "-c", "user.name=Graftty",
                "-c", "user.email=noreply@graftty.local",
                "commit", "--allow-empty", "-m", "Initial commit",
            ]
        }
        try await runStep(args: commitArgs, at: path)
    }

    /// Returns true iff both `user.name` and `user.email` resolve to
    /// non-empty values in this repo's effective git config. Uses
    /// `GitRunner.captureAll` so a non-zero exit (unset key) is observable
    /// without throwing.
    private static func hasConfiguredIdentity(at path: String) async -> Bool {
        @Sendable func probe(_ key: String) async -> Bool {
            do {
                let out = try await GitRunner.captureAll(
                    args: ["config", key], at: path
                )
                guard out.exitCode == 0 else { return false }
                return !out.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            } catch {
                return false
            }
        }
        async let hasEmail = probe("user.email")
        async let hasName = probe("user.name")
        let (email, name) = await (hasEmail, hasName)
        return email && name
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
