import Foundation

public struct TeamWatchInboxOwnershipDecision: Equatable, Sendable {
    public let shouldArmWatcher: Bool
    public let sessionID: String

    public init(shouldArmWatcher: Bool, sessionID: String) {
        self.shouldArmWatcher = shouldArmWatcher
        self.sessionID = sessionID
    }
}

public enum TeamWatchInboxOwnership {
    public static func decision(
        runtime: TeamHookRuntime,
        hookPayloadSessionID: String?,
        fallbackSessionID: () -> String,
        teamID: String,
        worktree: String,
        paneSessionName: String?,
        resolver: TeamDeliveryOwnershipResolver
    ) -> TeamWatchInboxOwnershipDecision {
        let sessionID = hookPayloadSessionID.flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackSessionID()
        let key = TeamDeliveryOwnerKey(
            teamID: teamID,
            worktree: worktree,
            runtime: runtime
        )
        let normalizedPaneSessionName = paneSessionName.flatMap { $0.isEmpty ? nil : $0 }
        let candidate = TeamDeliveryOwnerCandidate(
            key: key,
            paneSessionName: normalizedPaneSessionName,
            pid: nil,
            processStartTimeMicroseconds: nil,
            runtimeSessionID: sessionID
        )

        return TeamWatchInboxOwnershipDecision(
            shouldArmWatcher: resolver.isOwner(candidate, for: key),
            sessionID: sessionID
        )
    }
}
