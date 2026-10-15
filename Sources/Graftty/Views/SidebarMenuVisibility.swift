import Foundation
import GrafttyKit

/// Centralizes the "is this affordance shown?" predicates used by
/// the repo-row Add-Worktree `+` button and the worktree-row
/// Delete-Worktree context-menu item. Keeps the rules unit-testable
/// and lets the views stay focused on layout. PROJECT-1.1.
enum SidebarMenuVisibility {
    static func roleEditorDestination(worktree: WorktreeEntry, repo: RepoEntry, state: AppState) -> String? {
        guard let currentRepo = state.repos.first(where: { $0.id == repo.id }), currentRepo.path == repo.path,
              let currentWorktree = currentRepo.worktrees.first(where: { $0.id == worktree.id }),
              currentWorktree.path == worktree.path,
              showsEditRoleInstructions(worktree: currentWorktree, repo: currentRepo) else { return nil }
        let path = currentWorktree.state.hasOnDiskWorktree ? currentWorktree.path : currentRepo.path
        guard let destination = currentRepo.worktrees.first(where: { $0.path == path }),
              destination.state.hasOnDiskWorktree, !destination.state.isInFlight else { return nil }
        return path
    }

    static func showsEditRoleInstructions(worktree: WorktreeEntry, repo: RepoEntry) -> Bool {
        !worktree.state.isInFlight && SidebarHostNavigation.isPinned(worktree, in: repo)
    }
    static func showsAddWorktree(repo: RepoEntry) -> Bool {
        repo.isGitTracked
    }

    /// `git` refuses to remove the main checkout, so the existing
    /// `worktree.path != repo.path` guard hides the item for the
    /// main checkout of a git-tracked repo. For non-git repos the
    /// synthetic worktree's path always equals the repo path, so the
    /// same predicate covers `PROJECT-1.1` by construction without
    /// needing to read `isGitTracked` here.
    static func showsDeleteWorktree(worktree: WorktreeEntry, repo: RepoEntry) -> Bool {
        worktree.path != repo.path
    }
}
