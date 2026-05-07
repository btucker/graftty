import Foundation

/// Identity of a runtime+worktree slot in the agent-teams pipeline.
/// Used as a dictionary key by `WorktreeAgentStateRegistry` (state)
/// and `EngagedGraceScheduler` (per-slot timer). Hoisted out of both
/// types so they share one definition.
public struct AgentRuntimeKey: Hashable, Sendable {
    public let worktree: String
    public let runtime: String

    public init(worktree: String, runtime: String) {
        self.worktree = worktree
        self.runtime = runtime
    }
}
