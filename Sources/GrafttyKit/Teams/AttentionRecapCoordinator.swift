import Foundation
import GrafttyProtocol

public enum AttentionRecapStopAction: Equatable {
    case requestRecap
    case alreadyRecorded
    case record(AttentionRecap?)
}

/// Retains the current turn's published report for completion verification.
@MainActor
public final class AttentionRecapCoordinator {
    public static let shared = AttentionRecapCoordinator()

    private struct Key: Hashable {
        var worktree: String
        var agentID: String
    }

    private struct Report {
        let recap: AttentionRecap
        let reportedAt: Date
    }
    private var pending: [Key: Report] = [:]
    private var lastRecordedTurn: [Key: String] = [:]
    private var lastConsumedReport: [Key: Date] = [:]

    public init() {}

    @discardableResult
    public func report(_ recap: AttentionRecap, worktree: String, agentID: String, reportedAt: Date = Date()) -> Bool {
        let key = Key(worktree: worktree, agentID: agentID)
        // A socket retry may carry a receipt already completed through this
        // coordinator. It cannot satisfy a later peer turn's report check.
        guard lastConsumedReport[key].map({ reportedAt > $0 }) ?? true else { return false }
        guard pending[key].map({ reportedAt >= $0.reportedAt }) ?? true else { return false }
        pending[key] = Report(recap: recap, reportedAt: reportedAt)
        return true
    }

    public func reportedAt(worktree: String, agentID: String?) -> Date? {
        guard let agentID else { return nil }
        return pending[Key(worktree: worktree, agentID: agentID)]?.reportedAt
    }

    public func beginTurn(worktree: String, agentID: String?) {
        guard let agentID else { return }
        let key = Key(worktree: worktree, agentID: agentID)
        pending.removeValue(forKey: key)
        lastRecordedTurn.removeValue(forKey: key)
    }

    public func stop(worktree: String, agentID: String?, stopHookActive: Bool, turnID: String? = nil) -> AttentionRecapStopAction {
        guard let agentID, !agentID.isEmpty else { return .record(nil) }
        let key = Key(worktree: worktree, agentID: agentID)
        let completedTurn = turnID ?? "current"
        if lastRecordedTurn[key] == completedTurn { return .alreadyRecorded }
        let recap = pending[key]?.recap
        if recap == nil, !stopHookActive { return .requestRecap }
        lastRecordedTurn[key] = completedTurn
        if let report = pending.removeValue(forKey: key) {
            lastConsumedReport[key] = report.reportedAt
        }
        return .record(recap)
    }
}
