import Foundation

public extension WorktreeEntry {
    /// Reservations for another worktree do not elect or replace this worktree's primary.
    var hasCurrentAgent: Bool {
        agents.contains { $0.status != .closed && ($0.launchTargetWorktree == nil || $0.launchTargetWorktree == path) }
    }

    func isPrimaryAgent(_ agent: ManagedAgent) -> Bool {
        guard agent.launchTargetWorktree == nil || agent.launchTargetWorktree == path else { return false }
        if let primary = agent.isPrimary { return primary }
        // Durable record order preserves the original role after a legacy
        // primary closes. Tab order and current liveness must not promote a child.
        return agents.first {
            $0.launchTargetWorktree == nil || $0.launchTargetWorktree == path
        }?.id == agent.id
    }

    /// Mutate the outcome and binding in the same transaction that removes a
    /// pane. Hosts persist this together with the new tree/session inventory.
    mutating func recordManagedSessionEnd(slot: PaneSlotID, reason: String, preserveView: Bool = false) {
        for index in agents.indices where agents[index].paneSlotID == slot && agents[index].status != .closed {
            agents[index].retainedPaneSlotID = slot
            agents[index].sessionEnded(reason: reason, failedLaunch: agents[index].status == .starting)
            if !preserveView { agents[index].paneSlotID = nil }
        }
    }
}
