import Foundation

/// The agent identity `graftty attention report` files a recap under.
public enum AttentionReportIdentity {
    public struct UnmanagedAgent {
        public let agentID: String
        public let sessionID: String
        public let runtime: TeamHookRuntime
    }

    public static func unmanagedAgent(environment: [String: String]) -> UnmanagedAgent? {
        let codexSessionID = environment["CODEX_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
        let session: (TeamHookRuntime, String)?
        if let id = codexSessionID ?? environment["CODEX_THREAD_ID"], !id.isEmpty {
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
        let records = (try? TeamPresenceStorage(
            rootDirectory: TeamPresenceStorage.defaultRoot()
        ).listAll()) ?? []
        return currentAgentID(
            worktreePath: worktreePath, environment: environment, records: records,
            isReachable: TeamAgentReachability.isReachable
        )
    }

    static func currentAgentID(
        worktreePath: String,
        environment: [String: String],
        records: [TeamPresenceRecord],
        isReachable: (TeamPresenceRecord) -> Bool
    ) -> String? {
        return TeamCallerAgentIdentityResolver.resolve(
            explicitAgentID: environment["GRAFTTY_AGENT_ID"],
            worktree: worktreePath,
            paneSessionName: TeamRegisterPaneResolver.paneSessionName(env: environment),
            records: records,
            isReachable: isReachable
        )
    }
}
