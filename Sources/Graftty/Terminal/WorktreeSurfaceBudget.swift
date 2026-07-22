import Foundation
import GrafttyKit

/// @spec MEM-1.1
/// LRU cap on the number of worktrees whose Ghostty surfaces are kept
/// alive. User selections are most-recently-used; background-created
/// surfaces enter at the tail because they have never been selected. When
/// the budget overflows, the least-recently-selected worktree's leaves are
/// dispatched to `onEvict`. Self-prunes any LRU entry that is no longer in
/// the running snapshot, so stop/delete/stale transitions don't need to
/// call into the budget directly.
@MainActor
final class WorktreeSurfaceBudget {
    let capacity: Int
    private let onEvict: @MainActor (PaneSlotID) -> Void

    /// Most-recently-used first.
    private(set) var lru: [String] = []

    init(capacity: Int = 4, onEvict: @escaping @MainActor (PaneSlotID) -> Void) {
        self.capacity = capacity
        self.onEvict = onEvict
    }

    func noteSelected(
        worktreePath: String,
        splitTreesByPath: [String: SplitTree]
    ) {
        prune(using: splitTreesByPath)
        lru.removeAll { $0 == worktreePath }
        lru.insert(worktreePath, at: 0)
        enforceCapacity(using: splitTreesByPath)
    }

    /// Counts a surface created without a Mac-window selection (for example,
    /// web and CLI worktree creation) without pretending the user selected it.
    /// A never-selected worktree is least recent and may evict itself when the
    /// existing selected set already fills the budget; zmx keeps its process
    /// alive for later reattachment.
    func noteCreated(
        worktreePath: String,
        splitTreesByPath: [String: SplitTree]
    ) {
        prune(using: splitTreesByPath)
        if !lru.contains(worktreePath) {
            lru.append(worktreePath)
        }
        enforceCapacity(using: splitTreesByPath)
    }

    private func prune(using splitTreesByPath: [String: SplitTree]) {
        lru.removeAll { !splitTreesByPath.keys.contains($0) }
    }

    private func enforceCapacity(using splitTreesByPath: [String: SplitTree]) {
        while lru.count > capacity {
            let evictedPath = lru.removeLast()
            guard let tree = splitTreesByPath[evictedPath] else { continue }
            for leaf in tree.allLeaves {
                onEvict(leaf)
            }
        }
    }
}
