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

    /// @spec GIT-5.44
    /// When the user opens a terminal from a failed creation whose worktree exists, the application shall start a shell there even when a failed agent launch is recorded.
    func startsShellWhenSelected(openingTerminal: Bool) -> Bool {
        // Selecting a closed worktree that holds finished conversations shows them instead of a new shell.
        state == .closed && (openingTerminal || !agents.contains { $0.completion != nil })
    }

    /// Mutate the outcome and binding in the same transaction that removes a
    /// pane. Hosts persist this together with the new tree/session inventory.
    mutating func recordManagedSessionEnd(slot: PaneSlotID, reason: String, preserveView: Bool = false, hostStopped: Bool = false) {
        for index in agents.indices where agents[index].paneSlotID == slot && agents[index].status != .closed {
            agents[index].retainedPaneSlotID = slot
            agents[index].sessionEnded(reason: reason, failedLaunch: agents[index].status == .starting, hostStopped: hostStopped)
            if !preserveView { agents[index].paneSlotID = nil }
        }
    }
}
