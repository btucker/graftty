import Foundation
import GrafttyKit

/// @spec TEAM-IDLE-2.2
/// Per-(worktree, runtime) timer that fires 60 seconds after the last
/// keystroke. On fire, transitions the agent state from user_engaged
/// to idle (no-op if already not user_engaged) and triggers an
/// idle-delivery evaluation so any pending messages can drain.
@MainActor
final class EngagedGraceScheduler {
    private let state: WorktreeAgentStateRegistry
    private let onElapsed: @MainActor (_ worktree: String, _ runtime: String) -> Void
    private var timers: [AgentRuntimeKey: Timer] = [:]

    init(
        state: WorktreeAgentStateRegistry,
        onElapsed: @escaping @MainActor (String, String) -> Void
    ) {
        self.state = state
        self.onElapsed = onElapsed
    }

    /// Reset the per-(worktree, runtime) 60s countdown. Called on every
    /// keystroke so consecutive typing keeps the timer pushed forward.
    func bump(worktree: String, runtime: String) {
        let key = AgentRuntimeKey(worktree: worktree, runtime: runtime)
        timers[key]?.invalidate()
        timers[key] = Timer.scheduledTimer(
            withTimeInterval: WorktreeAgentStateRegistry.userEngagedGrace,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.state.handleEngagedGraceElapsed(worktree: worktree, runtime: runtime)
                self.onElapsed(worktree, runtime)
                self.timers.removeValue(forKey: key)
            }
        }
    }
}
