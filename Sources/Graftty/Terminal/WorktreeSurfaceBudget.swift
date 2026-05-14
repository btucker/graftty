import Foundation
import GrafttyKit

/// @spec MEM-1.1
/// LRU cap on the number of worktrees whose Ghostty surfaces are kept
/// alive. When `noteSelected` is called and the budget overflows, the
/// least-recently-selected worktree's leaves are dispatched to the
/// `onEvict` callback. Self-prunes any LRU entry that is no longer in
/// the running snapshot, so stop/delete/stale transitions don't need
/// to call into the budget directly.
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
        lru.removeAll { !splitTreesByPath.keys.contains($0) }
        lru.removeAll { $0 == worktreePath }
        lru.insert(worktreePath, at: 0)
        while lru.count > capacity {
            let evictedPath = lru.removeLast()
            guard let tree = splitTreesByPath[evictedPath] else { continue }
            for leaf in tree.allLeaves {
                onEvict(leaf)
            }
        }
    }
}
