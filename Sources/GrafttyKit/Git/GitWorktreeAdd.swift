import Foundation

/// Creates a new git worktree for a repository.
///
/// Switches argv based on `BranchSelection`: `.createNew` invokes
/// `git worktree add -b <branch> <path> [<start>]` (today's behavior);
/// `.useExisting` invokes `git worktree add <path> <branch|origin/branch>`
/// (no `-b`, no start point — the existing ref IS the start point).
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
            let ref: String
            switch source {
            case .local: ref = name
            case .remoteOnly: ref = "origin/" + name
            }
            return ["worktree", "add", worktreePath, ref]
        }
    }
}
