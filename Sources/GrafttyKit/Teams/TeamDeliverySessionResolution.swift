import Foundation

public enum TeamDeliverySessionResolution {
    public static func codexSessionNames(
        teamID: String,
        in worktree: String,
        records: [TeamPresenceRecord],
        isLiveSession: @escaping (String) -> Bool,
        processStartTimeMicroseconds: @escaping (Int32) -> Int64?
    ) -> [String] {
        let key = TeamDeliveryOwnerKey(
            teamID: teamID,
            worktree: worktree,
            runtime: .codex
        )
        let resolver = TeamDeliveryOwnershipResolver(
            records: { records },
            liveness: ClosureTeamDeliveryLiveness(
                isLiveSession: isLiveSession,
                processStartTimeMicroseconds: processStartTimeMicroseconds
            )
        )
        guard let owner = resolver.owner(for: key) else { return [] }
        return [owner.paneSessionName]
    }

    public static func stopSessionName(
        runtime: String,
        paneSessionName: String?,
        isLiveSession: (String) -> Bool
    ) -> String? {
        guard runtime == TeamHookRuntime.codex.rawValue,
              let sessionName = paneSessionName,
              isLiveSession(sessionName) else {
            return nil
        }
        return sessionName
    }
}

private struct ClosureTeamDeliveryLiveness: TeamDeliveryLivenessChecking, @unchecked Sendable {
    let isLiveSession: (String) -> Bool
    let readProcessStartTimeMicroseconds: (Int32) -> Int64?

    init(
        isLiveSession: @escaping (String) -> Bool,
        processStartTimeMicroseconds: @escaping (Int32) -> Int64?
    ) {
        self.isLiveSession = isLiveSession
        self.readProcessStartTimeMicroseconds = processStartTimeMicroseconds
    }

    func isLivePaneSession(_ sessionName: String) -> Bool {
        isLiveSession(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        readProcessStartTimeMicroseconds(pid)
    }
}
