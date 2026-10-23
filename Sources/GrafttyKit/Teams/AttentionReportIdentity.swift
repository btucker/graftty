import Foundation

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
