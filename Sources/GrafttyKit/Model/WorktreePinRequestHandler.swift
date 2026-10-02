import Foundation

/// Applies CLI pin changes through the same eligibility rules as the sidebar.
public enum WorktreePinRequestHandler {
    public static func handle(worktreePath: String, isPinned: Bool, state: inout AppState) -> ResponseMessage {
        guard let (repoIndex, worktreeIndex) = state.indices(forWorktreePath: worktreePath) else {
            return .error("unknown tracked worktree '\(worktreePath)'")
        }
        let repo = state.repos[repoIndex]
        let worktree = repo.worktrees[worktreeIndex]
        if worktree.path == repo.path {
            return isPinned ? .ok : .error("the default-branch checkout is always pinned")
        }
        guard !worktree.state.isInFlight else {
            return .error("cannot change pin state while a worktree operation is in progress")
        }
        if worktree.isPinned == isPinned { return .ok }
        guard SidebarHostNavigation.setPinned(isPinned, worktreeID: worktree.id, in: &state.repos) else {
            return .error("only an on-disk worktree can be pinned")
        }
        return .ok
    }
}
