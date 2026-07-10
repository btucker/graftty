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

    public static func pull(repoPath: String, branchName: String) async throws {
        guard !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.gitFailed(exitCode: 1, stderr: "default branch is unknown")
        }
        let currentBranch: String
        do {
            currentBranch = try await GitRunner.run(
                args: ["branch", "--show-current"],
                at: repoPath
            )
            guard currentBranch.trimmingCharacters(in: .whitespacesAndNewlines) == branchName else {
                throw Error.gitFailed(
                    exitCode: 1,
                    stderr: "default checkout is no longer on \(branchName)"
                )
            }
            _ = try await GitRunner.run(
                args: ["pull", "--ff-only", "origin", branchName],
                at: repoPath,
                timeout: .seconds(20)
            )
        } catch let err as GitDefaultBranchPull.Error {
            throw err
        } catch CLIError.nonZeroExit(_, let exitCode, let stderr) {
            throw Error.gitFailed(
                exitCode: exitCode,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "git pull --ff-only origin \(branchName) failed"
                    : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch CLIError.timedOut(_, let seconds) {
            throw Error.gitFailed(
                exitCode: 124,
                stderr: "git pull --ff-only origin \(branchName) timed out after \(Int(seconds)) seconds"
            )
        } catch let err as CLIError {
            throw Error.cliFailure(err)
        }
    }
}
