import Foundation

/// Shared watcher + cache teardown for a repo's worktrees. Called by
/// Remove Repository (LAYOUT-4.3) and the relocate cascade (LAYOUT-4.8)
/// — both need the same sequence for the same reasons: watcher-fd
/// lifetime (GIT-3.11), orphan-cache prevention (GIT-3.6 / GIT-4.10 /
/// GIT-3.13). The per-worktree `stopWatchingWorktree` loop is
/// load-bearing: linked worktrees can live outside `repo.path` (e.g.
/// `git worktree add /tmp/feature` from `/projects/foo`), so
/// `stopWatching(repoPath:)` alone would leak fds on detached-location
/// worktrees.
public enum RepoTeardown {
    @MainActor
    public static func stopWatchersAndClearCaches(
        repo: RepoEntry,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        remoteBranchStore: RemoteBranchStore? = nil
    ) {
        worktreeMonitor.stopWatching(repoPath: repo.path)
        for wt in repo.worktrees {
            worktreeMonitor.stopWatchingWorktree(wt.path)
            prStatusStore.clear(worktreePath: wt.path)
            statsStore.clear(worktreePath: wt.path)
        }
        remoteBranchStore?.clear(repoPath: repo.path)
    }
}
