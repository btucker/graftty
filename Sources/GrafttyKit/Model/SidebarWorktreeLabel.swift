import Foundation

/// Shared label rule for sidebar-adjacent worktree surfaces (row
/// label + right-click "Move to <name>" menu items). Routes the
/// main-checkout branch through `displayBranch` so a BIDI-override
/// scalar can't render RTL-reversed on any of those surfaces
/// (`GIT-2.10`).
public enum SidebarWorktreeLabel {
    public static func text(
        for worktree: WorktreeEntry,
        inRepoAtPath repoPath: String,
        siblingPaths: [String]
    ) -> String {
        if worktree.path == repoPath {
            return worktree.displayBranch
        }
        return worktree.displayName(amongSiblingPaths: siblingPaths)
    }
}
