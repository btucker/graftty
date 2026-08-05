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
/// Graftty-managed linked worktrees: label is the full name relative to
/// `<repo>/.worktrees`, preserving namespace components such as
/// `research/lead`. The sidebar hierarchy may shorten that to `lead` once it
/// has collected multiple `research/*` worktrees beneath a folder row.
///
/// Other linked worktrees: label is the directory basename, possibly
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
        if let relativeName = managedRelativeName(
            forPath: worktree.path,
            inRepoAtPath: repoPath
        ) {
            return relativeName
        }
        return worktree.displayName(amongSiblingPaths: siblingPaths)
    }

    /// Recovers the original slash-containing name for a worktree created
    /// beneath Graftty's known `<repo>/.worktrees` root. Component-wise
    /// comparison avoids treating paths such as `.worktrees-archive` as if
    /// they were descendants of `.worktrees`.
    public static func managedRelativeName(
        forPath worktreePath: String,
        inRepoAtPath repoPath: String
    ) -> String? {
        guard !worktreePath.isEmpty, !repoPath.isEmpty else { return nil }
        let rootComponents = URL(fileURLWithPath: repoPath)
            .appendingPathComponent(".worktrees", isDirectory: true)
            .standardizedFileURL
            .pathComponents
        let worktreeComponents = URL(fileURLWithPath: worktreePath)
            .standardizedFileURL
            .pathComponents
        guard worktreeComponents.count > rootComponents.count,
              worktreeComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return nil }
        return worktreeComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
