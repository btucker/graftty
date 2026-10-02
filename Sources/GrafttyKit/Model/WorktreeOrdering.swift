import Foundation

/// @spec LAYOUT-2.95: While a repository's worktree order is set to recent activity, the application shall continuously order its Tasks by their latest attention, agent progress, or stop time with the newest first, keep the main checkout first and stale Tasks last within that section, preserve manual Team order below Tasks, and decode older state without the setting as manual order.
public enum WorktreeOrderMode: String, Codable, Sendable, Equatable {
    case manual
    case recentActivity
}

public enum WorktreeOrdering {
    /// Newest `lastActivity` first; worktrees without activity keep their
    /// relative order after the active ones, and stale rows stay last.
    public static func byRecentActivity(_ worktrees: [WorktreeEntry]) -> [WorktreeEntry] {
        let keyed = worktrees.enumerated().map { (offset: $0.offset, element: $0.element, activity: $0.element.lastActivity) }
        let ordered = keyed.sorted { left, right in
            switch (left.activity, right.activity) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
        return staleLast(ordered)
    }

    public static func move(
        _ worktrees: [WorktreeEntry],
        movingIDs: [WorktreeEntry.ID],
        toIndex: Int
    ) -> [WorktreeEntry]? {
        guard !movingIDs.isEmpty else { return nil }
        guard toIndex >= 0 && toIndex <= worktrees.count else { return nil }

        let movingIDSet = Set(movingIDs)
        guard movingIDSet.count == movingIDs.count else { return nil }

        let indexByID = Dictionary(uniqueKeysWithValues: worktrees.enumerated().map { ($0.element.id, $0.offset) })
        guard movingIDs.allSatisfy({ indexByID[$0] != nil }) else { return nil }

        let moving = movingIDs.map { worktrees[indexByID[$0]!] }
        let base = worktrees.filter { !movingIDSet.contains($0.id) }
        let removedBeforeDestination = movingIDs.reduce(0) { count, id in
            count + ((indexByID[id] ?? worktrees.count) < toIndex ? 1 : 0)
        }
        let insertionIndex = toIndex - removedBeforeDestination
        guard insertionIndex >= 0 && insertionIndex <= base.count else { return nil }

        var reordered = base
        reordered.insert(contentsOf: moving, at: insertionIndex)
        return staleLast(reordered)
    }

    /// Moves stale Tasks last without changing the relative order of Team members.
    public static func staleLast(_ worktrees: [WorktreeEntry]) -> [WorktreeEntry] {
        var nonStale: [WorktreeEntry] = []
        var stale: [WorktreeEntry] = []
        nonStale.reserveCapacity(worktrees.count)
        stale.reserveCapacity(worktrees.count)

        var sawStale = false
        var needsReorder = false
        for worktree in worktrees {
            if worktree.state == .stale && !worktree.isTeamMember {
                sawStale = true
                stale.append(worktree)
            } else {
                if sawStale { needsReorder = true }
                nonStale.append(worktree)
            }
        }

        guard needsReorder else { return worktrees }
        return nonStale + stale
    }
}
