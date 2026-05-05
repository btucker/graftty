import Foundation
import GrafttyProtocol

/// Centralizes the lookups that the team-event pipeline needs against the
/// `[RepoEntry]` snapshot: resolving a `TeamView` from a worktree path,
/// finding a `TeamMember` by sanitized name across all repos, and
/// deriving the team ID used by `TeamInbox` so callers don't reproduce
/// the (currently `repo.path`) convention inline.
public enum TeamLookup {

    /// Resolves the `TeamView` for the worktree located at `worktreePath`.
    /// Returns nil when the path is not in any tracked repo or when the
    /// repo has fewer than two worktrees (matches `TeamView.team(for:in:teamsEnabled:)`
    /// with `teamsEnabled: true`).
    public static func team(for worktreePath: String, in repos: [RepoEntry]) -> TeamView? {
        for repo in repos {
            if let worktree = repo.worktrees.first(where: { $0.path == worktreePath }) {
                return TeamView.team(for: worktree, in: repos, teamsEnabled: true)
            }
        }
        return nil
    }

    /// Finds the first member whose sanitized `name` matches across all
    /// teams in `repos`. Used by the dispatcher when routing
    /// `team_message` to a named recipient.
    public static func member(named name: String, in repos: [RepoEntry]) -> TeamMember? {
        for repo in repos {
            guard let first = repo.worktrees.first else { continue }
            guard let team = TeamView.team(
                for: first,
                in: repos,
                teamsEnabled: true
            ) else { continue }
            if let match = team.memberNamed(name) {
                return match
            }
        }
        return nil
    }

    /// The team ID used for inbox storage. Currently the repo path —
    /// kept centralized so a future change (e.g. stable UUIDs) only
    /// touches this file.
    public static func id(of team: TeamView) -> String {
        team.repoPath
    }

    /// Same convention as `id(of:)` but derived directly from a repo
    /// path. Useful when a team has shrunk to one worktree (so
    /// `team(for:in:)` returns nil) but the dispatcher still needs to
    /// address the inbox bucket — e.g. when emitting a
    /// `team_member_left` row after the last coworker is removed.
    public static func id(forRepoPath repoPath: String) -> String {
        repoPath
    }
}
