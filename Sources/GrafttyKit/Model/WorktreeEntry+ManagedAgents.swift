import Foundation

public extension WorktreeEntry {
    /// Mutate the outcome and binding in the same transaction that removes a
    /// pane. Hosts persist this together with the new tree/session inventory.
    mutating func recordManagedSessionEnd(slot: PaneSlotID, reason: String) {
        for index in agents.indices where agents[index].paneSlotID == slot && agents[index].status != .closed {
            agents[index].retainedPaneSlotID = slot
            agents[index].sessionEnded(reason: reason, failedLaunch: agents[index].status == .starting)
            agents[index].paneSlotID = nil
        }
    }
}
