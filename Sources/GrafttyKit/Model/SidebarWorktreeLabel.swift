import Foundation

/// Shared label rule for sidebar-adjacent worktree surfaces (row
/// label + right-click "Move to <name>" menu items).
///
/// Main checkout: label is the repo's resolved default branch
/// (passed in by callers, who chain
/// `snapshot.defaultBranch ?? repo.defaultBranchHint`). Falls back
/// to `"main"` so the UI never goes blank. Stable across local
/// `git checkout`.
///
/// Linked worktrees: label is the directory basename, possibly
/// disambiguated against same-named siblings via
/// `WorktreeEntry.displayName(amongSiblingPaths:)`.
public enum SidebarWorktreeLabel {
    public static func texts(
        for worktrees: [WorktreeEntry],
        inRepoAtPath repoPath: String,
        defaultBranch: String?
    ) -> [WorktreeEntry.ID: String] {
        let siblingPaths = worktrees.map(\.path)
        return Dictionary(
            uniqueKeysWithValues: worktrees.map { worktree in
                (
                    worktree.id,
                    text(
                        for: worktree,
                        inRepoAtPath: repoPath,
                        siblingPaths: siblingPaths,
                        defaultBranch: defaultBranch
                    )
                )
            }
        )
    }

    public static func text(
        for worktree: WorktreeEntry,
        inRepoAtPath repoPath: String,
        siblingPaths: [String],
        defaultBranch: String?
    ) -> String {
        if worktree.path == repoPath {
            return defaultBranch ?? "main"
        }
        return worktree.displayName(amongSiblingPaths: siblingPaths)
    }
}
