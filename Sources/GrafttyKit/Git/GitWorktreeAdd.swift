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
        startPoint: String?
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

        let args = argvFor(
            branch: branch,
            worktreePath: worktreePath,
            startPoint: startPoint
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
            var args = ["worktree", "add", "-b", name, worktreePath]
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
