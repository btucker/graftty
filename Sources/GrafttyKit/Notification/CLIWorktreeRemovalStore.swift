import Foundation
import GrafttyProtocol

/// In-memory rendezvous between the fast local-socket acknowledgement and the
/// async shared worktree-removal flow. Terminal results are retained briefly
/// so the CLI can recover from a lost poll response.
@MainActor
public final class CLIWorktreeRemovalStore {
    private struct Record {
        var status: WorktreeRemoveStatus
        var updatedAt: Date
    }

    private var records: [String: Record] = [:]
    private let terminalRetention: TimeInterval

    public init(terminalRetention: TimeInterval = 10 * 60) {
        self.terminalRetention = terminalRetention
    }

    public func begin(
        worktreePath: String,
        now: Date = Date()
    ) -> WorktreeRemoveStatus {
        prune(now: now)
        let status = WorktreeRemoveStatus(
            operationID: UUID().uuidString.lowercased(),
            state: .pending,
            worktreePath: worktreePath
        )
        records[status.operationID] = Record(
            status: status,
            updatedAt: now
        )
        return status
    }

    public func markRemoved(operationID: String, now: Date = Date()) {
        transition(
            operationID: operationID,
            state: .removed,
            error: nil,
            forceAllowed: false,
            shortStatus: nil,
            now: now
        )
    }

    public func markFailed(
        operationID: String,
        error: String,
        forceAllowed: Bool,
        shortStatus: String? = nil,
        now: Date = Date()
    ) {
        transition(
            operationID: operationID,
            state: .failed,
            error: error,
            forceAllowed: forceAllowed,
            shortStatus: shortStatus,
            now: now
        )
    }

    public func status(
        operationID: String,
        now: Date = Date()
    ) -> WorktreeRemoveStatus? {
        prune(now: now)
        return records[operationID]?.status
    }

    public func hasPendingRemoval(
        worktreePath: String,
        now: Date = Date()
    ) -> Bool {
        prune(now: now)
        return records.values.contains {
            $0.status.worktreePath == worktreePath &&
                $0.status.state == .pending
        }
    }

    private func transition(
        operationID: String,
        state: WorktreeRemoveState,
        error: String?,
        forceAllowed: Bool,
        shortStatus: String?,
        now: Date
    ) {
        guard let record = records[operationID] else { return }
        records[operationID] = Record(
            status: WorktreeRemoveStatus(
                operationID: operationID,
                state: state,
                worktreePath: record.status.worktreePath,
                error: error,
                forceAllowed: forceAllowed,
                shortStatus: shortStatus
            ),
            updatedAt: now
        )
    }

    private func prune(now: Date) {
        records = records.filter { _, record in
            record.status.state == .pending ||
                now.timeIntervalSince(record.updatedAt) <= terminalRetention
        }
    }
}
