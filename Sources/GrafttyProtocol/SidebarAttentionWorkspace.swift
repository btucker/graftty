import Foundation

/// @spec LAYOUT-2.85: While Attention cards are retained, the application shall preserve them across acknowledgement, navigation, and relaunch without the recent-history limit; explicit dismissal shall hide the current request until a later request arrives.
///
/// Durable cards are separate from the bounded history of viewed requests.
/// An occurrence is retained for identity and acknowledgement; `isBusy` controls
/// its current presentation after the agent resumes.
public struct SidebarAttentionWorkspace: Codable, Sendable, Equatable {
    public private(set) var items: [SidebarActivityItem] = []
    private var dismissed: [String: SidebarAttentionOccurrence] = [:]

    public init() {}

    public func isDismissed(_ item: SidebarActivityItem) -> Bool {
        guard let previous = dismissed[item.id], let occurrence = item.occurrence else { return false }
        if occurrence == previous { return true }
        guard let timestamp = occurrence.timestamp, let previousTimestamp = previous.timestamp else { return false }
        return timestamp < previousTimestamp
    }

    public mutating func merge(_ live: [SidebarActivityItem]) {
        var additions: [SidebarActivityItem] = []
        let positions = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        for var item in SidebarActivityFilter.all.apply(to: live) {
            guard !isDismissed(item) else { continue }
            if let index = positions[item.id] {
                if item.needsAttention {
                    // A delayed snapshot must not replace a newer request.
                    guard (item.occurrence?.timestamp ?? .distantPast) >= (items[index].occurrence?.timestamp ?? .distantPast) else { continue }
                    item.isBusy = item.occurrence == items[index].occurrence && items[index].isBusy
                    items[index] = item
                } else {
                    items[index].isBusy = item.isBusy
                    items[index].prBadge = item.prBadge
                }
            } else if item.needsAttention, !additions.contains(where: { $0.id == item.id }) {
                item.isBusy = false
                dismissed[item.id] = nil
                additions.append(item)
            }
        }
        items.insert(contentsOf: additions, at: 0)
    }

    public mutating func reconcile(worktrees: [WorktreePanes]) {
        let live = SidebarProjection.activity(worktrees)
        merge(live)
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in items.indices {
            let item = items[index]
            guard let worktree = worktrees.first(where: {
                if let stableID = $0.sidebar?.id {
                    return item.id == stableID || item.id.hasPrefix(stableID + ":")
                }
                return item.worktreeID == $0.path
            }) else { continue } // Missing/offline snapshots do not dismiss cards.
            items[index].worktreeID = worktree.path
            items[index].projectID = SidebarProjection.projectID(worktree)
            items[index].projectName = worktree.repoDisplayName
            items[index].worktreeName = worktree.displayBranch
            items[index].worktreeEmoji = worktree.sidebar?.emoji
            items[index].prBadge = worktree.prBadge
            let route = SidebarProjection.attentionPaneRoute(for: item, in: worktree)
            if item.paneID != nil, let route { items[index].paneID = route }
            if let stop = item.agentStop {
                let progress = worktree.sidebar?.agentProgressTimes ?? [:]
                let resumedAt = stop.providerSessionKey.flatMap { progress[$0] }
                    ?? (stop.providerSessionKey == nil ? progress.values.max() : nil)
                if let resumedAt, resumedAt >= stop.timestamp {
                    items[index].isBusy = true
                } else if liveByID[item.id]?.needsAttention == true {
                    items[index].isBusy = false
                } else {
                    items[index].isBusy = worktree.layout?.leaves.first { $0.sessionName == route }?.isBusy == true
                }
            } else if liveByID[item.id]?.needsAttention == true {
                items[index].isBusy = false
            } else if let route {
                items[index].isBusy = worktree.layout?.leaves.first { $0.sessionName == route }?.isBusy == true
            } else {
                items[index].isBusy = worktree.layout?.leaves.contains(where: \.isBusy) == true
            }
        }
    }

    public mutating func dismiss(_ id: String) {
        if let occurrence = items.first(where: { $0.id == id })?.occurrence {
            dismissed[id] = occurrence
        }
        items.removeAll { $0.id == id }
    }
}
