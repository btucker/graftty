import Foundation

/// Resolves the set of recipient worktree paths for a routable team event,
/// given the event's subject, the repo state, and the user's routing matrix.
/// Implements TEAM-1.9.
public enum TeamEventRouter {
    public static func recipients(
        event: RoutableEvent,
        subjectWorktreePath: String,
        repos: [RepoEntry],
        preferences: TeamEventRoutingPreferences
    ) -> [String] {
        // Find the repo that contains the subject worktree.
        guard let repo = repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == subjectWorktreePath })
        }) else {
            return []
        }

        let row = event.recipientSet(in: preferences)

        // Single-worktree repos: only the worktree cell is meaningful.
        // Root + otherWorktrees cells are no-ops because there is no team.
        if repo.worktrees.count < 2 {
            return row.contains(.worktree) ? [subjectWorktreePath] : []
        }

        var paths: [String] = []
        if row.contains(.root) {
            paths.append(repo.path)
        }
        if row.contains(.worktree) {
            paths.append(subjectWorktreePath)
        }
        if row.contains(.otherWorktrees) {
            for wt in repo.worktrees
                where wt.path != subjectWorktreePath && wt.path != repo.path {
                paths.append(wt.path)
            }
        }

        // Dedupe while preserving order: the subject may equal the root.
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
