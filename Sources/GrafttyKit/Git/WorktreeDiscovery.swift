import Foundation

/// Dispatches worktree discovery for a `RepoEntry`. Git-tracked repos
/// shell out to `git worktree list --porcelain` (the existing
/// `GitWorktreeDiscovery.discover` path). Non-git repos return a
/// single synthetic worktree at the repo path with branch label
/// `placeholderBranch` (PROJECT-1.4), so the rest of the reconcile,
/// sidebar, and persistence code keeps working unchanged.
public enum WorktreeDiscovery {
    /// Branch label used for the synthetic worktree of a non-git repo
    /// — both when the entry is first created (`AddRepositoryAlert`)
    /// and when the reconciler rediscovers it. The two sites must
    /// agree, so the literal lives here once.
    public static let placeholderBranch = "main"

    public static func discover(repo: RepoEntry) async throws -> [DiscoveredWorktree] {
        if repo.isGitTracked {
            return try await GitWorktreeDiscovery.discover(repoPath: repo.path)
        }
        return [DiscoveredWorktree(path: repo.path, branch: placeholderBranch)]
    }
}
