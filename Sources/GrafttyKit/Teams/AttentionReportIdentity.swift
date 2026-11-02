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
        if let id = codexSessionID(environment: environment) {
            session = (.codex, id)
        } else if let id = claudeSessionID(environment: environment) {
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

    /// CODEX_SESSION_ID can be a shared ancestor session. Thread identity
    /// prevents a child from borrowing its parent's pane (AGENT-3.20).
    static func codexSessionID(environment: [String: String]) -> String? {
        firstNonEmpty(["CODEX_THREAD_ID", "CODEX_SESSION_ID"], in: environment)
    }

    /// Claude Code exports its own session as `CLAUDE_CODE_SESSION_ID`, the
    /// same ID its hooks register, so it outranks a wrapper's explicit
    /// `CLAUDE_SESSION_ID` (AGENT-3.32).
    static func claudeSessionID(environment: [String: String]) -> String? {
        firstNonEmpty(["CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID"], in: environment)
    }

    private static func firstNonEmpty(_ keys: [String], in environment: [String: String]) -> String? {
        for key in keys {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return nil
    }

    public static func currentAgentID(worktreePath: String, runtime: TeamHookRuntime? = nil, sessionID: String? = nil) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let records = (try? TeamPresenceStorage(
            rootDirectory: TeamPresenceStorage.defaultRoot()
        ).listAll()) ?? []
        return currentAgentID(
            worktreePath: worktreePath, environment: environment, records: records,
            isReachable: hasCurrentProcessIdentity, runtime: runtime, sessionID: sessionID
        )
    }

    // Reporting uses files, not the delivery transport. Socket metadata can
    // be inaccessible in the provider sandbox even while this process lives.
    static func hasCurrentProcessIdentity(_ record: TeamPresenceRecord) -> Bool {
        guard record.pid > 0, let expected = record.processStartTimeMicroseconds else { return false }
        return ProcessIdentityReader.startTimeMicroseconds(ofPID: record.pid) == expected
    }

    static func currentAgentID(
        worktreePath: String,
        environment: [String: String],
        records: [TeamPresenceRecord],
        isReachable: (TeamPresenceRecord) -> Bool,
        runtime: TeamHookRuntime? = nil, sessionID: String? = nil
    ) -> String? {
        // Hook input identifies the provider directly. Shell reports first
        // establish pane ownership so inherited variables from another
        // provider cannot hide a valid registration.
        let runtimeRecords = records.filter { runtime == nil || $0.runtime == runtime }
        func resolve(_ candidates: [TeamPresenceRecord]) -> String? {
            TeamCallerAgentIdentityResolver.resolve(
                explicitAgentID: environment["GRAFTTY_AGENT_ID"],
                worktree: worktreePath,
                paneSessionName: TeamRegisterPaneResolver.paneSessionName(env: environment),
                records: candidates, isReachable: isReachable
            )
        }
        guard let identity = resolve(runtimeRecords) else { return nil }
        let ownedRecords = runtimeRecords.filter { record in
            guard TeamAgentDirectory.identity(for: record).rawValue == identity else { return false }
            let nativeID: String?
            if let sessionID {
                nativeID = sessionID
            } else if record.runtime == .codex {
                nativeID = codexSessionID(environment: environment)
            } else {
                nativeID = claudeSessionID(environment: environment)
            }
            return nativeID == nil || record.runtimeSessionID == nativeID
        }
        return resolve(ownedRecords)
    }
}
