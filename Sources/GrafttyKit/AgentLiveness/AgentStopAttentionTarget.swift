import Foundation

/// Where an agent-stop "needs input" overlay should land: the agent's pane
/// when its session resolves, otherwise the worktree (agent not in a pane).
public enum AgentStopAttentionTarget: Equatable {
    case pane(PaneSlotID)
    case worktree

    public static func resolve(worktree: WorktreeEntry, paneSessionName: String?) -> AgentStopAttentionTarget {
        if let name = paneSessionName, let slot = worktree.paneSlot(forSessionName: name) {
            return .pane(slot)
        }
        return .worktree
    }
}
