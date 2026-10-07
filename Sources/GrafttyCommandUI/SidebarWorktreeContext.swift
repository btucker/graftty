import Foundation
import GrafttyProtocol

/// A report is retained context; only live occurrences can request attention.
public struct SidebarWorktreeContext: Equatable {
    public let worktree: WorktreePanes
    public let item: SidebarActivityItem
    public let pending: [SidebarActivityItem]
    public let question: String?
    public let questionPaneID: String?
    public let isRunning: Bool

    public init(worktree: WorktreePanes, retained: [SidebarActivityItem] = [],
                isViewed: (SidebarActivityItem) -> Bool = { _ in false }) {
        self.worktree = worktree
        let projectID = SidebarProjection.projectID(worktree)
        let stableID = worktree.sidebar?.id ?? "\(projectID):\(worktree.path)"
        let live = SidebarProjection.activity([worktree])
        let saved = retained.filter { $0.projectID == projectID && $0.worktreeID == worktree.path }
        let stop = ([worktree.sidebar?.unseenAgentStop, worktree.sidebar?.lastAgentStop].compactMap { $0 }
            + saved.compactMap(\.agentStop)).max { $0.timestamp < $1.timestamp }
        var target = live.first ?? SidebarActivityItem(id: stableID, projectID: projectID,
            worktreeID: worktree.path, paneID: nil, projectName: worktree.repoDisplayName,
            worktreeName: worktree.displayName, title: worktree.displayName, occurrence: nil, isBusy: false)
        if let stop {
            target = SidebarActivityItem(id: stableID + ":stop", projectID: projectID,
                worktreeID: worktree.path, paneID: nil, projectName: worktree.repoDisplayName,
                worktreeName: worktree.displayName, title: stop.title, occurrence: stop.occurrence,
                isBusy: false, agentStop: stop)
        }
        target.branchName = worktree.displayBranch
        target.worktreeEmoji = worktree.effectiveEmoji
        target.isMainCheckout = worktree.isMainCheckout
        target.prBadge = worktree.prBadge
        let route = SidebarProjection.attentionPaneRoute(for: target, in: worktree)
        let progress = worktree.sidebar?.agentProgressTimes ?? [:]
        let resumedAt = stop?.providerSessionKey.flatMap { progress[$0] }
            ?? (stop?.providerSessionKey == nil ? progress.values.max() : nil)
        let resumed = stop.map { (resumedAt ?? -.infinity) >= $0.timestamp } ?? false
        let busy = resumed || worktree.layout?.leaves.first(where: { $0.sessionName == route })?.isBusy == true
        target.isBusy = busy
        self.item = target
        self.isRunning = busy
        self.pending = live.filter { candidate in
            candidate.needsAttention && !candidate.isBusy && !isViewed(candidate)
                && !(candidate.agentStop != nil && busy)
                && !(candidate.agentStop.map { $0.timestamp < (stop?.timestamp ?? -.infinity) } ?? false)
        }
        let currentQuestion = pending.contains { $0.id == target.id && $0.occurrence == target.occurrence }
            ? stop?.recap?.need : nil
        self.question = currentQuestion
        self.questionPaneID = currentQuestion == nil ? nil : route
    }

    public func matches(query: String) -> Bool {
        SidebarInteractionPolicy.matches(worktree, query: query)
            || !SidebarActivityFilter.all.apply(to: [item] + pending, query: query).isEmpty
    }
}

extension SidebarNavigationState {
    public func nextPendingWorktree(in worktrees: [WorktreePanes], projectID: String?, after path: String?) -> SidebarActivityItem? {
        var seen: Set<String> = []
        let rows = worktrees.filter {
            let project = SidebarProjection.projectID($0)
            let identity = "\(project.utf8.count):\(project)\($0.path)"
            return (projectID == nil || project == projectID) && $0.state.hasOnDiskWorktree && seen.insert(identity).inserted
        }
        guard !rows.isEmpty else { return nil }
        let start = path.flatMap { path in rows.firstIndex { $0.path == path } }.map { $0 + 1 } ?? 0
        for offset in 0..<rows.count {
            let context = worktreeContext(rows[(start + offset) % rows.count])
            if let item = context.pending.first { return item }
        }
        return nil
    }
}
