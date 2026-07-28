import Foundation

/// Creates a new git worktree for a repository.
///
/// Switches argv based on `BranchSelection`:
/// - `.createNew` → `git worktree add -b <branch> <path> [<start>]`.
/// - `.useExisting(.local)` → `git worktree add <path> <branch>` —
///   git checks out the existing local branch (not detached).
/// - `.useExisting(.remoteOnly)` → `git worktree add --track -b <branch> <path> origin/<branch>` —
///   `--track -b` is required: bare `git worktree add <path> origin/<branch>` treats the
///   remote-tracking ref as a commit-ish and produces a detached HEAD.
public enum GitWorktreeAdd {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
        /// Git failed to launch or was not found on PATH. Wraps the
        /// underlying `CLIError` so callers can distinguish "git ran
        /// and rejected the request" (where stderr is meaningful) from
        /// "git never ran" (where a generic failure message is right).
        case cliFailure(CLIError)
    }

    public static func add(
        repoPath: String,
        worktreePath: String,
        branch: BranchSelection,
        startPoint: String?,
        startPointResolutionPath: String? = nil
    ) async throws {
        if case .useExisting(let name, .local) = branch {
            let ref = "refs/heads/\(name)"
            let check: CLIOutput
            do {
                check = try await GitRunner.captureAll(
                    args: ["show-ref", "--verify", "--quiet", ref],
                    at: repoPath
                )
            } catch let err as CLIError {
                throw Error.cliFailure(err)
            }
            guard check.exitCode == 0 else {
                throw Error.gitFailed(
                    exitCode: check.exitCode,
                    stderr: "local branch does not exist: \(name)"
                )
            }
        }

        let resolvedStartPoint: String?
        if let startPointResolutionPath,
           let startPoint,
           !startPoint.isEmpty {
            let result: CLIOutput
            do {
                result = try await GitRunner.captureAll(
                    args: [
                        "rev-parse",
                        "--verify",
                        "--end-of-options",
                        "\(startPoint)^{commit}",
                    ],
                    at: startPointResolutionPath
                )
            } catch let err as CLIError {
                throw Error.cliFailure(err)
            }
            guard result.exitCode == 0 else {
                let stderr = result.stderr
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw Error.gitFailed(
                    exitCode: result.exitCode,
                    stderr: stderr.isEmpty
                        ? "base revision does not resolve to a commit: \(startPoint)"
                        : stderr
                )
            }
            resolvedStartPoint = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedStartPoint = startPoint
        }

        let args = argvFor(
            branch: branch,
            worktreePath: worktreePath,
            startPoint: resolvedStartPoint
        )
        let result: CLIOutput
        do {
            result = try await GitRunner.captureAll(args: args, at: repoPath)
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

    nonisolated static func argvFor(
        branch: BranchSelection,
        worktreePath: String,
        startPoint: String?
    ) -> [String] {
        switch branch {
        case .createNew(let name):
            // End option parsing before the caller-controlled path and base
            // revision. This keeps an option-shaped revision an operand that
            // Git can either resolve or reject, never an accidental flag.
            var args = ["worktree", "add", "-b", name, "--", worktreePath]
            if let startPoint, !startPoint.isEmpty {
                args.append(startPoint)
            }
            return args
        case .useExisting(let name, let source):
            precondition(
                startPoint == nil,
                "GitWorktreeAdd: startPoint must be nil when branch is .useExisting (caller should pass nil)"
            )
            switch source {
            case .local:
                // End option parsing before the path/branch operands. Git
                // otherwise accepts an option-shaped branch after <path>.
                return ["worktree", "add", "--", worktreePath, name]
            case .remoteOnly:
                return ["worktree", "add", "--track", "-b", name, worktreePath, "origin/" + name]
            }
        }
    }
}
