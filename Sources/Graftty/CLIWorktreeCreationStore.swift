import Foundation
import GrafttyKit

enum CLIWorktreeCreationPolicy {
    static func validationError(agentRuntime: TeamHookRuntime?, teamsEnabled: Bool) -> String? {
        guard agentRuntime != nil, !teamsEnabled else { return nil }
        return "Agent Teams is disabled; enable it in Graftty Settings before using --agent"
    }
}

/// In-memory rendezvous between the fast local-socket request and the async
/// Git/surface work. Terminal results are retained briefly so a lost socket
/// response can be retried with the same operation ID.
@MainActor
final class CLIWorktreeCreationStore {
    private struct Record {
        var status: WorktreeCreateStatus
        var updatedAt: Date
    }

    private var records: [String: Record] = [:]
    private let terminalRetention: TimeInterval

    init(terminalRetention: TimeInterval = 10 * 60) {
        self.terminalRetention = terminalRetention
    }

    func begin(worktreePath: String, messageAddress: String, now: Date = Date()) -> WorktreeCreateStatus {
        prune(now: now)
        let status = WorktreeCreateStatus(
            operationID: UUID().uuidString.lowercased(),
            state: .pending,
            worktreePath: worktreePath,
            messageAddress: messageAddress
        )
        records[status.operationID] = Record(status: status, updatedAt: now)
        return status
    }

    func markReady(operationID: String, now: Date = Date()) {
        transition(operationID: operationID, state: .ready, error: nil, now: now)
    }

    func markFailed(operationID: String, error: String, now: Date = Date()) {
        transition(operationID: operationID, state: .failed, error: error, now: now)
    }

    func status(operationID: String, now: Date = Date()) -> WorktreeCreateStatus? {
        prune(now: now)
        return records[operationID]?.status
    }

    private func transition(
        operationID: String,
        state: WorktreeCreateState,
        error: String?,
        now: Date
    ) {
        guard let record = records[operationID] else { return }
        let prior = record.status
        records[operationID] = Record(
            status: WorktreeCreateStatus(
                operationID: operationID,
                state: state,
                worktreePath: prior.worktreePath,
                messageAddress: prior.messageAddress,
                error: error
            ),
            updatedAt: now
        )
    }

    private func prune(now: Date) {
        records = records.filter { _, record in
            record.status.state == .pending || now.timeIntervalSince(record.updatedAt) <= terminalRetention
        }
    }
}
