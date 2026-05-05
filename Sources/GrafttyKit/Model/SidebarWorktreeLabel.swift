import Foundation

/// Shared label rule for sidebar-adjacent worktree surfaces (row
/// label + right-click "Move to <name>" menu items). Routes the
/// main-checkout branch through `displayBranch` so a BIDI-override
/// scalar can't render RTL-reversed on any of those surfaces
/// (`GIT-2.10`).
public enum SidebarWorktreeLabel {
    public static func texts(
        for worktrees: [WorktreeEntry],
        inRepoAtPath repoPath: String
    ) -> [WorktreeEntry.ID: String] {
        let siblingPaths = worktrees.map(\.path)
        return Dictionary(
            uniqueKeysWithValues: worktrees.map { worktree in
                (
                    worktree.id,
                    text(
                        for: worktree,
                        inRepoAtPath: repoPath,
                        siblingPaths: siblingPaths
                    )
                )
            }
        )
    }

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
