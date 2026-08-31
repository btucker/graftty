import Foundation

/// Keeps one canonical Claude identity for a live native peer endpoint.
/// Claude `/clear` starts a new logical session without replacing the process
/// or messaging socket, so process liveness alone cannot retire the old row.
public enum ClaudeHookSessionBinder {
    @discardableResult
    public static func bind(
        _ incoming: TeamPresenceRecord,
        event: TeamHookEvent,
        storage: TeamPresenceStorage
    ) throws -> TeamPresenceRecord? {
        guard incoming.runtime == .claude,
              incoming.agentID != nil,
              incoming.runtimeSessionID != nil,
              case .claude = incoming.transport else {
            return nil
        }

        let endpointRecords = try storage.listAll().filter {
            sameEndpoint($0, incoming)
        }
        let winner: TeamPresenceRecord
        if event == .sessionStart {
            winner = incoming
        } else if endpointRecords.contains(where: {
            sameIdentityFile($0, incoming)
        }) {
            winner = endpointRecords.max(by: isOlder) ?? incoming
        } else if let existing = endpointRecords.max(by: isOlder) {
            // A late Stop or PostToolUse hook can carry the identity that
            // `/clear` just superseded. Do not recreate a deleted identity
            // while another session owns the same live endpoint.
            winner = existing
        } else {
            // Plugin installation can occur during a live Claude session,
            // after its SessionStart hook has already passed.
            winner = incoming
        }

        for record in endpointRecords where !sameIdentityFile(record, winner) {
            try storage.delete(
                teamID: record.teamID,
                worktree: record.worktree,
                runtime: record.runtime,
                paneSessionName: record.paneSessionName,
                agentID: record.agentID
            )
        }

        guard sameIdentityFile(winner, incoming) else { return winner }
        if !endpointRecords.contains(incoming) {
            try storage.write(incoming)
        }
        return incoming
    }

    private static func sameEndpoint(
        _ lhs: TeamPresenceRecord,
        _ rhs: TeamPresenceRecord
    ) -> Bool {
        guard lhs.teamID == rhs.teamID,
              lhs.worktree == rhs.worktree,
              lhs.runtime == .claude,
              rhs.runtime == .claude,
              lhs.pid == rhs.pid,
              lhs.processStartTimeMicroseconds == rhs.processStartTimeMicroseconds,
              case .claude(let lhsPath, let lhsVersion) = lhs.transport,
              case .claude(let rhsPath, let rhsVersion) = rhs.transport else {
            return false
        }
        return lhsPath == rhsPath && lhsVersion == rhsVersion
    }

    private static func sameIdentityFile(
        _ lhs: TeamPresenceRecord,
        _ rhs: TeamPresenceRecord
    ) -> Bool {
        lhs.agentID == rhs.agentID
            && lhs.paneSessionName == rhs.paneSessionName
    }

    private static func isOlder(
        _ lhs: TeamPresenceRecord,
        _ rhs: TeamPresenceRecord
    ) -> Bool {
        if lhs.registeredAt != rhs.registeredAt {
            return lhs.registeredAt < rhs.registeredAt
        }
        return (lhs.agentID ?? "") < (rhs.agentID ?? "")
    }
}
