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
    private let lock = NSLock()
    private var states: [Key: AgentState] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func state(worktree: String, runtime: String) -> AgentState {
        lock.lock(); defer { lock.unlock() }
        return states[Key(worktree, runtime)] ?? .unknown
    }

    public func handleSessionStart(worktree: String, runtime: String) {
        set(.active, worktree: worktree, runtime: runtime)
    }

    public func handlePostToolUse(worktree: String, runtime: String) {
        set(.active, worktree: worktree, runtime: runtime)
    }

    public func handleStop(worktree: String, runtime: String, lastInputAt: Date?) {
        let recentlyTyping: Bool = {
            guard let lastInputAt else { return false }
            return now().timeIntervalSince(lastInputAt) < Self.userEngagedGrace
        }()
        set(recentlyTyping ? .user_engaged : .idle, worktree: worktree, runtime: runtime)
    }

    public func handleKeystroke(worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(worktree, runtime)
        if states[key] == .idle { states[key] = .user_engaged }
    }

    public func handleEngagedGraceElapsed(worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(worktree, runtime)
        if states[key] == .user_engaged { states[key] = .idle }
    }

    public func removeState(worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        states.removeValue(forKey: Key(worktree, runtime))
    }

    private func set(_ state: AgentState, worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        states[Key(worktree, runtime)] = state
    }

    private struct Key: Hashable {
        let worktree: String
        let runtime: String
        init(_ w: String, _ r: String) { self.worktree = w; self.runtime = r }
    }
}
