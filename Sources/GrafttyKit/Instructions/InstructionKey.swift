import Foundation

/// @spec INSTR-2.1
/// The application shall derive a worktree instruction key from its path relative to the repository worktrees directory, from the resolved default branch for the main checkout, and shall produce no key for worktrees outside that directory.
public struct InstructionKey {
    /// Derives an instruction key for a worktree from its paths and default branch.
    /// - Returns: A string key representing either the relative path (for worktrees) or default branch (for main checkout), or nil if no key can be derived.
    public static func key(
        worktreePath: String,
        repoPath: String,
        defaultBranch: String?
    ) -> String? {
        // Normalize paths: remove trailing slashes and resolve dot segments
        let normalizedWorktreePath = (worktreePath as NSString).standardizingPath
        let normalizedRepoPath = (repoPath as NSString).standardizingPath

        // Check if this is the main checkout
        if normalizedWorktreePath == normalizedRepoPath {
            // Main checkout uses the default branch name as the key
            return defaultBranch
        }

        // Check if the worktree is in the .worktrees directory
        let worktreesDir = (normalizedRepoPath as NSString).appendingPathComponent(".worktrees")

        guard normalizedWorktreePath.hasPrefix(worktreesDir + "/") else {
            return nil
        }

        // Extract the relative path from .worktrees/
        let relativePath = String(normalizedWorktreePath.dropFirst(worktreesDir.count + 1))

        return relativePath.isEmpty ? nil : relativePath
    }
}
