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
    @discardableResult
    public static func bind(
        threadID: String,
        teamID: String,
        worktree: String,
        paneSessionName: String,
        agentID: String,
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
