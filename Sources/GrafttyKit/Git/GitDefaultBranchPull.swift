import Foundation

/// Pulls the repository's main checkout before creating a worktree from
/// the origin default branch.
public enum GitDefaultBranchPull {

    public enum Error: Swift.Error, Equatable {
        /// Non-zero exit from git, with stderr included for display.
        case gitFailed(exitCode: Int32, stderr: String)
        /// Git failed to launch or was not found on PATH.
        case cliFailure(CLIError)
    }

    public static func pull(repoPath: String) async throws {
        let result: CLIOutput
        do {
            result = try await GitRunner.captureAll(
                args: ["pull", "--ff-only"],
                at: repoPath
            )
        } catch let err as CLIError {
            throw Error.cliFailure(err)
        }
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: stderr.isEmpty ? "git pull --ff-only failed" : stderr
            )
        }
    }
}

