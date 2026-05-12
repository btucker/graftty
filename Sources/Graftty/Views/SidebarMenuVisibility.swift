import Foundation
import GrafttyKit

/// Centralizes the "is this affordance shown?" predicates used by
/// the repo-row Add-Worktree `+` button and the worktree-row
/// Delete-Worktree context-menu item. Keeps the rules unit-testable
/// and lets the views stay focused on layout. PROJECT-1.1.
enum SidebarMenuVisibility {
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
