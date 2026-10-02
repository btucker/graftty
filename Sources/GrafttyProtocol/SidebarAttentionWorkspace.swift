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

    /// Collapse each worktree to one representative card; `newestFirst`
    /// then ranks the result, so the slot kept here only breaks ties.
    public static func cards(from items: [SidebarActivityItem]) -> [SidebarActivityItem] {
        var rows: [SidebarActivityItem] = []
        var positions: [SidebarActivityItem.WorktreeIdentity: Int] = [:]
        for item in items {
            guard let index = positions[item.worktreeIdentity] else {
                positions[item.worktreeIdentity] = rows.count
                rows.append(item)
                continue
            }
            let previous = rows[index]
            let pending = item.needsAttention && !item.isBusy
            let previousPending = previous.needsAttention && !previous.isBusy
            if pending != previousPending {
                if pending { rows[index] = item }
                continue
            }
            let timestamp = item.occurrence?.timestamp ?? .distantPast
            let previousTimestamp = previous.occurrence?.timestamp ?? .distantPast
            if timestamp > previousTimestamp
                || (timestamp == previousTimestamp && item.agentStop?.recap != nil && previous.agentStop?.recap == nil) {
                rows[index] = item
            }
        }
        return rows
    }

    /// @spec LAYOUT-2.94: While Attention cards are displayed, the application shall order them newest first by each card's latest report time and move a card to the top when a newer report arrives for its worktree.
    public static func newestFirst(_ rows: [SidebarActivityItem]) -> [SidebarActivityItem] {
        rows.enumerated().sorted { left, right in
            let leftTime = reportTime(left.element), rightTime = reportTime(right.element)
            return leftTime == rightTime ? left.offset < right.offset : leftTime > rightTime
        }.map(\.element)
    }

    private static func reportTime(_ item: SidebarActivityItem) -> Date {
        item.occurrence?.timestamp ?? item.runningSince ?? .distantPast
    }

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
                    item.runningSince = item.isBusy ? items[index].runningSince : nil
                    items[index] = item
                } else {
                    items[index].worktreeName = item.worktreeName
                    items[index].branchName = item.branchName
                    items[index].runningSince = item.isBusy ? items[index].runningSince ?? item.runningSince ?? Date() : nil
                    items[index].isBusy = item.isBusy
                    items[index].prBadge = item.prBadge
                }
            } else if item.needsAttention, !additions.contains(where: { $0.id == item.id }) {
                item.isBusy = false
                dismissed[item.id] = nil
                additions.append(item)
            }
        }
        for item in additions.reversed() {
            let position = items.firstIndex { $0.worktreeIdentity == item.worktreeIdentity } ?? 0
            items.insert(item, at: position)
        }
    }

    public mutating func reconcile(worktrees: [WorktreePanes], availableProjectIDs: Set<String> = []) {
        let live = SidebarProjection.activity(worktrees)
        merge(live)
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var deletedIDs: Set<String> = []
        for index in items.indices {
            let item = items[index]
            guard let worktree = worktrees.first(where: {
                if let stableID = $0.sidebar?.id {
                    return item.id == stableID || item.id.hasPrefix(stableID + ":")
                }
                return item.worktreeID == $0.path
            }) else {
                if availableProjectIDs.contains(item.projectID) { deletedIDs.insert(item.id) }
                continue // Offline and incomplete snapshots do not remove cards.
            }
            items[index].worktreeID = worktree.path
            items[index].projectID = SidebarProjection.projectID(worktree)
            items[index].projectName = worktree.repoDisplayName
            items[index].worktreeName = worktree.displayName
            items[index].branchName = worktree.displayBranch
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
                    items[index].runningSince = Date(timeIntervalSinceReferenceDate: resumedAt)
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
            if items[index].isBusy {
                items[index].runningSince = items[index].runningSince ?? liveByID[item.id]?.runningSince ?? Date()
            } else {
                items[index].runningSince = nil
            }
        }
        items.removeAll { deletedIDs.contains($0.id) }
    }

    public mutating func dismiss(_ id: String) {
        guard let target = items.first(where: { $0.id == id }) else { return }
        for item in items where item.worktreeIdentity == target.worktreeIdentity {
            if let occurrence = item.occurrence { dismissed[item.id] = occurrence }
        }
        items.removeAll { $0.worktreeIdentity == target.worktreeIdentity }
    }
}
