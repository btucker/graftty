import Foundation

/// Resolves a free-form existing branch against exact refs on the owning Mac.
///
/// Local wins when both refs exist, matching the native branch picker's
/// preference. Remote-only is selected only when `refs/heads/<name>` is
/// absent and `refs/remotes/origin/<name>` exists.
public enum GitExistingBranchSource {
    public static func resolve(
        repoPath: String,
        branchName: String
    ) async throws -> BranchSelection.ExistingSource? {
        if try await contains(
            ref: "refs/heads/\(branchName)",
            repoPath: repoPath
        ) {
            return .local
        }
        if try await contains(
            ref: "refs/remotes/origin/\(branchName)",
            repoPath: repoPath
        ) {
            return .remoteOnly
        }
        return nil
    }

    private static func contains(
        ref: String,
        repoPath: String
    ) async throws -> Bool {
        let result = try await GitRunner.captureAll(
            args: ["show-ref", "--verify", "--quiet", ref],
            at: repoPath
        )
        return result.exitCode == 0
    }
}
