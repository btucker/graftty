import GrafttyProtocol

/// Freezes presentation positions while continuing to use live worktree content.
struct MobileWorktreeReportOrder {
    let worktrees: [WorktreePanes]
    let projects: [SidebarProject]

    func orderedWorktrees(_ live: [WorktreePanes]) -> [WorktreePanes] {
        let current = Dictionary(live.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let frozenKeys = Set(worktrees.map(key))
        return worktrees.compactMap { frozen in
            guard let row = current[key(frozen)] else { return nil }
            var metadata = row.sidebar
            metadata?.isPinned = frozen.sidebar?.isPinned
            metadata?.folders = frozen.sidebar?.folders ?? []
            metadata?.folderIDs = frozen.sidebar?.folderIDs
            return WorktreePanes(path: row.path, displayName: row.displayName, repoDisplayName: row.repoDisplayName,
                repositoryID: row.repositoryID, displayBranch: row.displayBranch, state: row.state,
                isMainCheckout: row.isMainCheckout, prBadge: row.prBadge, stats: row.stats,
                attentionText: row.attentionText, attentionSource: row.attentionSource, attentionTimestamp: row.attentionTimestamp,
                layout: row.layout, origin: row.origin, route: row.route, sidebar: metadata)
        } + live.filter { !frozenKeys.contains(key($0)) }
    }

    func orderedProjects(_ live: [SidebarProject]) -> [SidebarProject] {
        let current = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let frozenIDs = Set(projects.map(\.id))
        return projects.compactMap { current[$0.id] } + live.filter { !frozenIDs.contains($0.id) }
    }

    private func key(_ worktree: WorktreePanes) -> String {
        SidebarProjection.projectID(worktree) + "\u{0}" + worktree.path
    }
}
