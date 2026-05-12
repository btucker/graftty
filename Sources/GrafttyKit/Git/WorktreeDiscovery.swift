import Foundation

/// Dispatches worktree discovery for a `RepoEntry`. Git-tracked repos
/// shell out to `git worktree list --porcelain` (the existing
/// `GitWorktreeDiscovery.discover` path). Non-git repos return a
/// single synthetic worktree at the repo path with branch label
/// `"main"` (PROJECT-1.4), so the rest of the reconcile, sidebar,
/// and persistence code keeps working unchanged.
public enum WorktreeDiscovery {
    public static func discover(repo: RepoEntry) async throws -> [DiscoveredWorktree] {
        if repo.isGitTracked {
            return try await GitWorktreeDiscovery.discover(repoPath: repo.path)
        }
        return [DiscoveredWorktree(path: repo.path, branch: "main")]
    }
}
