import GrafttyProtocol

public struct TeamMember: Sendable, Equatable {
    public let name: String           // sanitized branch
    public let worktreePath: String
    public let branch: String
    public let isMainWorktree: Bool
    public let isRunning: Bool
    public let hasOnDiskWorktree: Bool

    public init(
        name: String,
        worktreePath: String,
        branch: String,
        isMainWorktree: Bool,
        isRunning: Bool,
        hasOnDiskWorktree: Bool = true
    ) {
        self.name = name
        self.worktreePath = worktreePath
        self.branch = branch
        self.isMainWorktree = isMainWorktree
        self.isRunning = isRunning
        self.hasOnDiskWorktree = hasOnDiskWorktree
    }
}

/// Read-only view over `AppState` that describes the team a worktree belongs to.
///
/// Implements TEAM-2.* from SPECS.md. There is no persisted team registry —
/// membership is derived live from `RepoEntry.worktrees`.
public struct TeamView: Sendable, Equatable {
    public let repoPath: String
    public let repoDisplayName: String
    /// `members[0]` is always the repository's main worktree, enforced by
    /// the static factory `team(for:in:teamsEnabled:)`.
    public let members: [TeamMember]

    /// Internal so external modules must construct via `team(for:in:teamsEnabled:)`,
    /// which enforces the "members[0] is the main worktree, count >= 2" invariant.
    internal init(repoPath: String, repoDisplayName: String, members: [TeamMember]) {
        self.repoPath = repoPath
        self.repoDisplayName = repoDisplayName
        self.members = members
    }

    public var mainWorktree: TeamMember {
        // Guaranteed non-empty by the static factory.
        members.first(where: \.isMainWorktree)
            ?? members[0]
    }

    public func memberNamed(_ name: String) -> TeamMember? {
        // Canonical worktree paths are stable across branch switches and do
        // not collide under the lossy display-name sanitizer. Keep legacy
        // branch-derived names as a convenience fallback.
        members.first(where: { $0.worktreePath == name })
            ?? members.first(where: { $0.name == name })
    }

    public func peers(of worktree: WorktreeEntry) -> [TeamMember] {
        members.filter { $0.worktreePath != worktree.path }
    }

    /// Resolves the team for a given worktree. Returns nil when team mode is
    /// off, the worktree's repo is not in `repos`, or the repo has fewer than
    /// two worktrees (a one-worktree repo has no team).
    public static func team(
        for worktree: WorktreeEntry,
        in repos: [RepoEntry],
        teamsEnabled: Bool
    ) -> TeamView? {
        guard teamsEnabled else { return nil }
        guard let repo = repos.first(where: { $0.worktrees.contains(where: { $0.id == worktree.id }) }) else {
            return nil
        }
        guard repo.worktrees.count >= 2 else { return nil }

        let members = repo.worktrees.map { wt -> TeamMember in
            TeamMember(
                name: WorktreeNameSanitizer.sanitize(wt.branch),
                worktreePath: wt.path,
                branch: wt.branch,
                isMainWorktree: wt.path == repo.path,
                isRunning: wt.state == .running,
                hasOnDiskWorktree: wt.state.hasOnDiskWorktree
            )
        }.sorted { lhs, rhs in
            // Main worktree first, then linked worktrees in worktree-add order.
            if lhs.isMainWorktree != rhs.isMainWorktree { return lhs.isMainWorktree }
            return false
        }

        return TeamView(
            repoPath: repo.path,
            repoDisplayName: repo.displayName,
            members: members
        )
    }
}
