import Foundation

/// @spec TEAM-IDLE-2.13
/// Testable core of `team unregister`. Returns the prior record (if any)
/// so the caller can decide whether to emit an `unregistered` event.
public enum TeamUnregisterCore {
    @discardableResult
    public static func unregister(
        storage: TeamPresenceStorage,
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) throws -> TeamPresenceRecord? {
        let prior = try storage.read(
            teamID: teamID, worktree: worktree,
            runtime: runtime, paneSessionName: paneSessionName
        )
        try storage.delete(
            teamID: teamID, worktree: worktree,
            runtime: runtime, paneSessionName: paneSessionName
        )
        return prior
    }
}
