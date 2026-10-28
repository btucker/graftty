import Foundation
import GrafttyProtocol

public enum AttentionRecapStopAction: Equatable {
    case alreadyRecorded
    case record(AttentionRecap?)
}

/// Holds a report until the reporting agent's next stopped turn.
@MainActor
public final class AttentionRecapCoordinator {
    public static let shared = AttentionRecapCoordinator()

    private struct Key: Hashable {
        var worktree: String
        var agentID: String
    }

    private var pending: [Key: AttentionRecap] = [:]
    private var lastRecordedTurn: [Key: String] = [:]

    public init() {}

    public func report(_ recap: AttentionRecap, worktree: String, agentID: String) {
        pending[Key(worktree: worktree, agentID: agentID)] = recap
    }

    public func beginTurn(worktree: String, agentID: String?) {
        guard let agentID else { return }
        pending.removeValue(forKey: Key(worktree: worktree, agentID: agentID))
    }

    public func stop(worktree: String, agentID: String?, stopHookActive: Bool, turnID: String? = nil) -> AttentionRecapStopAction {
        guard let agentID, !agentID.isEmpty else { return .record(nil) }
        let key = Key(worktree: worktree, agentID: agentID)
        if let turnID {
            if lastRecordedTurn[key] == turnID { return .alreadyRecorded }
            lastRecordedTurn[key] = turnID
        }
        if let recap = pending[key] {
            pending.removeValue(forKey: key)
            return .record(recap)
        }
        return .record(nil)
    }
}
