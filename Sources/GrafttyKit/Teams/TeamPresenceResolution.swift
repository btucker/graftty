import Foundation

/// Resolves a worktree's team for `team register` / `team unregister` /
/// `team hook`. Presence ownership and inbox delivery use the canonical
/// worktree path; the member name is display-only compatibility metadata.
/// Returns nil when the path is not a tracked, team-enabled worktree so
/// the wrapper-driven CLI calls can no-op cleanly.
public enum TeamPresenceResolution {
    public struct Resolved {
        public let team: TeamView
        public let worktreePath: String
        public let memberName: String

        public init(team: TeamView, worktreePath: String, memberName: String) {
            self.team = team
            self.worktreePath = worktreePath
            self.memberName = memberName
        }
    }

    public static func resolveTeamAndWorktree(worktreePath: String) -> Resolved? {
        guard let state = try? AppState.load(from: AppState.defaultDirectory) else {
            return nil
        }
        return resolveTeamAndWorktree(state: state, worktreePath: worktreePath)
    }

    public static func resolveTeamAndWorktree(state: AppState, worktreePath: String) -> Resolved? {
        guard let team = TeamLookup.team(for: worktreePath, in: state.repos) else {
            return nil
        }
        guard let worktreeName = team.members.first(where: { $0.worktreePath == worktreePath })?.name else {
            return nil
        }
        return Resolved(team: team, worktreePath: worktreePath, memberName: worktreeName)
    }

    @discardableResult
    public static func deleteLegacyMemberNamePresence(
        storage: TeamPresenceStorage,
        teamID: String,
        resolved: Resolved,
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) throws -> TeamPresenceRecord? {
        guard resolved.memberName != resolved.worktreePath else { return nil }
        let prior = try storage.read(
            teamID: teamID,
            worktree: resolved.memberName,
            runtime: runtime,
            paneSessionName: paneSessionName
        )
        try storage.delete(
            teamID: teamID,
            worktree: resolved.memberName,
            runtime: runtime,
            paneSessionName: paneSessionName
        )
        return prior
    }
}
