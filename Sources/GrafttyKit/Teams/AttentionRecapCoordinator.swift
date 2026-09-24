import Foundation
import GrafttyProtocol

public enum AttentionRecapStopAction: Equatable {
    case requestRecap
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

    public init() {}

    public func report(_ recap: AttentionRecap, worktree: String, agentID: String) {
        pending[Key(worktree: worktree, agentID: agentID)] = recap
    }

    public func stop(worktree: String, agentID: String?, stopHookActive: Bool) -> AttentionRecapStopAction {
        guard let agentID, !agentID.isEmpty else { return .record(nil) }
        let key = Key(worktree: worktree, agentID: agentID)
        if let recap = pending.removeValue(forKey: key) {
            return .record(recap)
        }
        return stopHookActive ? .record(nil) : .requestRecap
    }
}
