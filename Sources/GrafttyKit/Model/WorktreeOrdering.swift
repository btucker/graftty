import Foundation

public enum WorktreeOrdering {
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

    public static func staleLast(_ worktrees: [WorktreeEntry]) -> [WorktreeEntry] {
        var nonStale: [WorktreeEntry] = []
        var stale: [WorktreeEntry] = []
        nonStale.reserveCapacity(worktrees.count)
        stale.reserveCapacity(worktrees.count)

        var sawStale = false
        var needsReorder = false
        for worktree in worktrees {
            if worktree.state == .stale {
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
