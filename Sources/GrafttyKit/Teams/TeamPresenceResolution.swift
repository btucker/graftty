import Foundation

/// Resolves a worktree's team for `team register` / `team unregister` /
/// `team hook`. Presence ownership and inbox delivery use the canonical
/// worktree path; the member name is display-only compatibility metadata.
/// Returns nil when the worktree is not tracked and team-enabled so the
/// wrapper-driven CLI calls can no-op cleanly.
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

/// The agent identity `graftty attention report` files a recap under.
public enum AttentionReportIdentity {
    public struct UnmanagedAgent {
        public let agentID: String
        public let sessionID: String
        public let runtime: TeamHookRuntime
    }

    public static func unmanagedAgent(environment: [String: String]) -> UnmanagedAgent? {
        let session: (TeamHookRuntime, String)?
        if let id = environment["CODEX_SESSION_ID"] ?? environment["CODEX_THREAD_ID"], !id.isEmpty {
            session = (.codex, id)
        } else if let id = environment["CLAUDE_SESSION_ID"], !id.isEmpty {
            session = (.claude, id)
        } else {
            session = nil
        }
        guard let (runtime, sessionID) = session else { return nil }
        return UnmanagedAgent(
            agentID: TeamAgentIdentity(runtime: runtime, nativeSessionID: sessionID).rawValue,
            sessionID: sessionID,
            runtime: runtime
        )
    }

    public static func currentAgentID(worktreePath: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["GRAFTTY_AGENT_ID"]
            .flatMap(TeamAgentIdentity.init(rawValue:)) {
            return explicit.rawValue
        }
        let records = (try? TeamPresenceStorage(
            rootDirectory: TeamPresenceStorage.defaultRoot()
        ).listAll()) ?? []
        return TeamCallerAgentIdentityResolver.resolve(
            explicitAgentID: nil,
            worktree: worktreePath,
            paneSessionName: TeamRegisterPaneResolver.paneSessionName(env: environment),
            records: records,
            isReachable: TeamAgentReachability.isReachable
        )
    }
}
