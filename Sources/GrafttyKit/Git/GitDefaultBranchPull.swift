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

    public static func pull(
        repoPath: String,
        branchName: String,
        using executor: CLIExecutor? = nil
    ) async throws {
        guard !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.gitFailed(exitCode: 1, stderr: "default branch is unknown")
        }
        let currentBranch: String
        var commandArgs = ["branch", "--show-current"]
        do {
            currentBranch = try await GitRunner.run(
                args: commandArgs,
                at: repoPath,
                timeout: .seconds(5),
                using: executor
            )
            guard currentBranch.trimmingCharacters(in: .whitespacesAndNewlines) == branchName else {
                throw Error.gitFailed(
                    exitCode: 1,
                    stderr: "default checkout is no longer on \(branchName)"
                )
            }
            commandArgs = ["pull", "--ff-only", "origin", branchName]
            _ = try await GitRunner.run(
                args: commandArgs,
                at: repoPath,
                timeout: .seconds(20),
                using: executor
            )
        } catch let err as GitDefaultBranchPull.Error {
            throw err
        } catch CLIError.nonZeroExit(_, let exitCode, let stderr) {
            throw Error.gitFailed(
                exitCode: exitCode,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "git \(commandArgs.joined(separator: " ")) failed"
                    : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch CLIError.timedOut(_, let seconds) {
            throw Error.gitFailed(
                exitCode: 124,
                stderr: "git \(commandArgs.joined(separator: " ")) timed out after \(Int(seconds)) seconds"
            )
        } catch let err as CLIError {
            throw Error.cliFailure(err)
        }
    }
}
