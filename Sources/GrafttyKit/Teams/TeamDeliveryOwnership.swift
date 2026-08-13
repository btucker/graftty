import Foundation

public struct TeamDeliveryOwnerKey: Hashable, Sendable {
    public let teamID: String
    public let worktree: String
    public let runtime: TeamHookRuntime

    public init(teamID: String, worktree: String, runtime: TeamHookRuntime) {
        self.teamID = teamID
        self.worktree = worktree
        self.runtime = runtime
    }
}

public struct TeamDeliveryOwner: Equatable, Sendable {
    public let key: TeamDeliveryOwnerKey
    public let paneSessionName: String
    public let pid: Int32
    public let processStartTimeMicroseconds: Int64
    public let registeredAt: Date
    public let runtimeSessionID: String?
    public let agentID: String

    public init(
        key: TeamDeliveryOwnerKey,
        paneSessionName: String,
        pid: Int32,
        processStartTimeMicroseconds: Int64,
        registeredAt: Date,
        runtimeSessionID: String?,
        agentID: String
    ) {
        self.key = key
        self.paneSessionName = paneSessionName
        self.pid = pid
        self.processStartTimeMicroseconds = processStartTimeMicroseconds
        self.registeredAt = registeredAt
        self.runtimeSessionID = runtimeSessionID
        self.agentID = agentID
    }
}

public struct TeamDeliveryOwnerCandidate: Sendable {
    public let key: TeamDeliveryOwnerKey
    public let paneSessionName: String?
    public let pid: Int32?
    public let processStartTimeMicroseconds: Int64?
    public let runtimeSessionID: String?

    public init(
        key: TeamDeliveryOwnerKey,
        paneSessionName: String?,
        pid: Int32?,
        processStartTimeMicroseconds: Int64?,
        runtimeSessionID: String?
    ) {
        self.key = key
        self.paneSessionName = paneSessionName
        self.pid = pid
        self.processStartTimeMicroseconds = processStartTimeMicroseconds
        self.runtimeSessionID = runtimeSessionID
    }
}

public protocol TeamDeliveryLivenessChecking: Sendable {
    func isLivePaneSession(_ sessionName: String) -> Bool
    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64?
}

public struct TeamDeliveryOwnershipResolver: Sendable {
    public let records: @Sendable () -> [TeamPresenceRecord]
    public let liveness: any TeamDeliveryLivenessChecking

    public init(
        records: @escaping @Sendable () -> [TeamPresenceRecord],
        liveness: any TeamDeliveryLivenessChecking
    ) {
        self.records = records
        self.liveness = liveness
    }

    public func owner(for key: TeamDeliveryOwnerKey) -> TeamDeliveryOwner? {
        records()
            .compactMap { ownerCandidate(from: $0, matching: key) }
            .sorted { lhs, rhs in
                if lhs.registeredAt != rhs.registeredAt {
                    return lhs.registeredAt < rhs.registeredAt
                }
                if lhs.paneSessionName != rhs.paneSessionName {
                    return lhs.paneSessionName < rhs.paneSessionName
                }
                return lhs.pid < rhs.pid
            }
            .first
    }

    public func isOwner(
        _ candidate: TeamDeliveryOwnerCandidate,
        for key: TeamDeliveryOwnerKey
    ) -> Bool {
        guard candidate.key == key,
              let candidatePaneSessionName = candidate.paneSessionName,
              let owner = owner(for: key),
              candidatePaneSessionName == owner.paneSessionName else {
            return false
        }

        if let candidatePID = candidate.pid, candidatePID != owner.pid {
            return false
        }
        if let candidateStart = candidate.processStartTimeMicroseconds,
           candidateStart != owner.processStartTimeMicroseconds {
            return false
        }
        return true
    }

    private func ownerCandidate(
        from record: TeamPresenceRecord,
        matching key: TeamDeliveryOwnerKey
    ) -> TeamDeliveryOwner? {
        guard record.teamID == key.teamID,
              record.worktree == key.worktree,
              record.runtime == key.runtime,
              record.isSubagent != true,
              let paneSessionName = record.paneSessionName,
              liveness.isLivePaneSession(paneSessionName),
              let recordedStart = record.processStartTimeMicroseconds,
              liveness.processStartTimeMicroseconds(ofPID: record.pid) == recordedStart else {
            return nil
        }

        return TeamDeliveryOwner(
            key: key,
            paneSessionName: paneSessionName,
            pid: record.pid,
            processStartTimeMicroseconds: recordedStart,
            registeredAt: record.registeredAt,
            runtimeSessionID: record.runtimeSessionID,
            agentID: TeamAgentDirectory.identity(for: record).rawValue
        )
    }
}
