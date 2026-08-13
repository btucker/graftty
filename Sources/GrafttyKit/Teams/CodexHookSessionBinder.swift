import Foundation

public struct CodexHookSessionBinding: Equatable, Sendable {
    public let agentID: String
    public let threadID: String
    public let socketPath: String
}

public enum CodexHookSessionBinder {
    /// Joins the two facts established at different points in wrapper startup:
    /// the transport socket registered before the TUI launches and the exact
    /// thread ID reported later by Codex's SessionStart hook.
    ///
    /// `allowRebind` is true only for session-start invocations: once a
    /// non-empty thread ID is bound, a straggling post-tool-use hook from a
    /// superseded thread may fill an empty binding or confirm a matching one,
    /// but must not steer the records back into a dead thread.
    @discardableResult
    public static func bind(
        threadID: String,
        teamID: String,
        worktree: String,
        paneSessionName: String,
        agentID: String,
        allowRebind: Bool,
        presenceStorage: TeamPresenceStorage,
        sessionStorage: CodexAppServerSessionStorage
    ) throws -> CodexHookSessionBinding? {
        guard !threadID.isEmpty,
              let presence = try presenceStorage.read(
                  teamID: teamID,
                  worktree: worktree,
                  runtime: .codex,
                  paneSessionName: paneSessionName,
                  agentID: agentID
              ),
              let session = try sessionStorage.read(
                  teamID: teamID,
                  worktree: worktree,
                  paneSessionName: paneSessionName
              ) else {
            return nil
        }

        // A straggling post-tool-use hook can still carry the thread ID of a
        // session that a re-host/resume has already superseded; rewriting the
        // records would steer native delivery into the dead thread. Only
        // session-start may replace an established, different binding.
        if !allowRebind,
           let boundThreadID = session.threadID,
           !boundThreadID.isEmpty,
           boundThreadID != threadID {
            return CodexHookSessionBinding(
                agentID: session.agentID ?? agentID,
                threadID: boundThreadID,
                socketPath: session.socketPath
            )
        }

        let boundSession = CodexAppServerSessionRecord(
            teamID: session.teamID,
            worktree: session.worktree,
            paneSessionName: session.paneSessionName,
            socketPath: session.socketPath,
            realBinaryPath: session.realBinaryPath,
            appServerPID: session.appServerPID,
            appServerProcessStartTimeMicroseconds: session.appServerProcessStartTimeMicroseconds,
            registeredAt: session.registeredAt,
            agentID: agentID,
            threadID: threadID,
            activeTurnID: nil
        )
        let boundPresence = TeamPresenceRecord(
            teamID: presence.teamID,
            worktree: presence.worktree,
            runtime: presence.runtime,
            paneSessionName: presence.paneSessionName,
            pid: presence.pid,
            processStartTimeMicroseconds: presence.processStartTimeMicroseconds,
            registeredAt: presence.registeredAt,
            runtimeSessionID: threadID,
            nativeDisplayName: presence.nativeDisplayName,
            agentID: agentID,
            transport: .codex(
                binaryPath: session.realBinaryPath,
                socketPath: session.socketPath,
                threadID: threadID,
                activeTurnID: nil
            ),
            isSubagent: presence.isSubagent == true
        )
        // Hooks fire on every tool call; skip the two file writes when the
        // binding is already exactly what we would write.
        if boundSession != session {
            try sessionStorage.write(boundSession)
        }
        if boundPresence != presence {
            try presenceStorage.write(boundPresence)
        }
        return CodexHookSessionBinding(
            agentID: agentID,
            threadID: threadID,
            socketPath: session.socketPath
        )
    }
}
