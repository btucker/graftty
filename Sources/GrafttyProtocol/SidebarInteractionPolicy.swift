import Foundation

public enum SidebarInteractionPolicy {
    public static func stoppedTurnAcknowledgement(for worktree: WorktreePanes) -> WorktreeManagementRequest? {
        guard let stop = worktree.sidebar?.unseenAgentStop else { return nil }
        return .acknowledgeOccurrence(worktreeID: worktree.path, paneID: nil, occurrence: stop.occurrence)
    }

    /// A legacy acknowledgement has broader semantics and can clear a request
    /// that the user has not seen. Opening the target remains supported.
    public static func acknowledgement(for item: SidebarActivityItem, supportsExactAcknowledgement: Bool) -> WorktreeManagementRequest? {
        guard supportsExactAcknowledgement, let occurrence = item.occurrence else { return nil }
        return .acknowledgeOccurrence(worktreeID: item.worktreeID, paneID: item.paneID, occurrence: occurrence)
    }

    /// Opening agent content records a visit without retiring its request,
    /// but it does retire a finished turn that asked nothing.
    /// Explicit dismissal continues to use `acknowledgement(for:)`.
    public static func acknowledgementOnOpen(for item: SidebarActivityItem,
                                             supportsExactAcknowledgement: Bool) -> WorktreeManagementRequest? {
        // Opening is seeing a finished turn that asked nothing; the host
        // records that turn per worktree, not per pane.
        if item.agentStop != nil, !item.needsAttention {
            var worktreeScoped = item
            worktreeScoped.paneID = nil
            return acknowledgement(for: worktreeScoped, supportsExactAcknowledgement: supportsExactAcknowledgement)
        }
        guard item.occurrence?.source != .agentStop else { return nil }
        return acknowledgement(for: item, supportsExactAcknowledgement: supportsExactAcknowledgement)
    }

    public static func matches(_ worktree: WorktreePanes, query: String) -> Bool {
        matches(query: query, projectName: worktree.repoDisplayName,
                worktreeName: worktree.displayName, branch: worktree.displayBranch)
    }

    public static func matches(query: String, projectName: String, worktreeName: String, branch: String) -> Bool {
        query.isEmpty || "\(projectName) \(worktreeName) \(branch)".localizedCaseInsensitiveContains(query)
    }
}
