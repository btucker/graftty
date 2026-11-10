import GrafttyProtocol

/// Retained input is indexed when it changes, rather than copied and scanned
/// for every row, section, count, and search during view evaluation.
struct SidebarRetainedReportIndex {
    private struct WorktreeIdentity: Hashable {
        let projectID: String
        let path: String
    }

    private var items: [SidebarActivityItem] = []
    private var byID: [String: [Int]] = [:]
    private var byWorktree: [WorktreeIdentity: [Int]] = [:]

    init(sources: [[SidebarActivityItem]] = []) {
        items.reserveCapacity(sources.reduce(0) { $0 + $1.count })
        for source in sources {
            for item in source {
                let position = items.count
                items.append(item)
                byID[item.id, default: []].append(position)
                byWorktree[WorktreeIdentity(projectID: item.projectID, path: item.worktreeID), default: []].append(position)
            }
        }
    }

    func reports(for worktree: WorktreePanes) -> [SidebarActivityItem] {
        let positions: [Int]
        if let id = worktree.sidebar?.id {
            positions = byID[id + ":stop"] ?? []
        } else {
            positions = byWorktree[WorktreeIdentity(projectID: SidebarProjection.projectID(worktree), path: worktree.path)] ?? []
        }
        // Keep source order, including duplicates: the existing newest-stop
        // selection also defines which report wins when timestamps tie.
        return positions.map { items[$0] }
    }
}
