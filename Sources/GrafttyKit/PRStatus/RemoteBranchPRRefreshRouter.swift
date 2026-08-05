import Foundation

/// Routes a remote-ref snapshot transition into the narrow PR cache actions
/// that it requires. Keeping this seam in GrafttyKit lets the app wiring and
/// its behavioral test share the same repo-scoped pulse path.
@MainActor
public enum RemoteBranchPRRefreshRouter {
    public static func route(
        repo: RepoEntry,
        oldBranches: Set<String>,
        newBranches: Set<String>,
        clear: (String) -> Void,
        pulseRepo: (String) -> Void
    ) {
        for worktree in repo.worktrees where worktree.state.hasOnDiskWorktree {
            if oldBranches.contains(worktree.branch)
                && !newBranches.contains(worktree.branch) {
                clear(worktree.path)
            }
        }

        if !newBranches.subtracting(oldBranches).isEmpty {
            pulseRepo(repo.path)
        }
    }
}
