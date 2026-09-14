import Foundation

public enum SidebarInteractionPolicy {
    /// A legacy acknowledgement has broader semantics and can clear a request
    /// that the user has not seen. Opening the target remains supported.
    public static func acknowledgement(for item: SidebarActivityItem, supportsExactAcknowledgement: Bool) -> WorktreeManagementRequest? {
        guard supportsExactAcknowledgement, let occurrence = item.occurrence else { return nil }
        return .acknowledgeOccurrence(worktreeID: item.worktreeID, paneID: item.paneID, occurrence: occurrence)
    }

    public static func matches(_ worktree: WorktreePanes, query: String) -> Bool {
        matches(query: query, projectName: worktree.repoDisplayName,
                worktreeName: worktree.displayName, branch: worktree.displayBranch)
    }

    public static func matches(query: String, projectName: String, worktreeName: String, branch: String) -> Bool {
        query.isEmpty || "\(projectName) \(worktreeName) \(branch)".localizedCaseInsensitiveContains(query)
    }
}
