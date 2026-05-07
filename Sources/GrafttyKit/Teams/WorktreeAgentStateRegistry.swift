import Foundation

/// @spec TEAM-IDLE-2.1
/// @spec TEAM-IDLE-2.2
/// In-process state machine, one record per (worktree, runtime).
/// Hook events drive active ↔ idle / user_engaged transitions; the
/// 60-second user_engaged grace is driven by the consumer scheduling
/// `handleEngagedGraceElapsed` after the last keystroke.
public final class WorktreeAgentStateRegistry: @unchecked Sendable {
    public enum AgentState: String, Sendable {
        case unknown, active, idle, user_engaged
    }

    public static let userEngagedGrace: TimeInterval = 60

    private let now: @Sendable () -> Date
    private let states = LockedDictionary<AgentRuntimeKey, AgentState>()

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func state(worktree: String, runtime: String) -> AgentState {
        states.get(AgentRuntimeKey(worktree: worktree, runtime: runtime)) ?? .unknown
    }

    public func handleSessionStart(worktree: String, runtime: String) {
        states.set(AgentRuntimeKey(worktree: worktree, runtime: runtime), .active)
    }

    public func handlePostToolUse(worktree: String, runtime: String) {
        states.set(AgentRuntimeKey(worktree: worktree, runtime: runtime), .active)
    }

    public func handleStop(worktree: String, runtime: String, lastInputAt: Date?) {
        let recentlyTyping: Bool = {
            guard let lastInputAt else { return false }
            return now().timeIntervalSince(lastInputAt) < Self.userEngagedGrace
        }()
        states.set(
            AgentRuntimeKey(worktree: worktree, runtime: runtime),
            recentlyTyping ? .user_engaged : .idle
        )
    }

    public func handleKeystroke(worktree: String, runtime: String) {
        states.update(AgentRuntimeKey(worktree: worktree, runtime: runtime)) { value in
            if value == .idle { value = .user_engaged }
        }
    }

    public func handleEngagedGraceElapsed(worktree: String, runtime: String) {
        states.update(AgentRuntimeKey(worktree: worktree, runtime: runtime)) { value in
            if value == .user_engaged { value = .idle }
        }
    }

    public func removeState(worktree: String, runtime: String) {
        states.remove(AgentRuntimeKey(worktree: worktree, runtime: runtime))
    }
}
