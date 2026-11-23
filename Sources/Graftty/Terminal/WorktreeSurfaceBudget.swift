import Foundation
import GrafttyKit

/// @spec MEM-1.1
/// While more than 4 worktrees have live surfaces, the application shall evict the least-recently-selected worktree outside the open windows. A background-created worktree that has never been selected enters as least recent.
@MainActor
final class WorktreeSurfaceBudget {
    let capacity: Int
    private let onEvict: @MainActor (PaneSlotID) -> Void
    var isPresented: (String) -> Bool = { _ in false }

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
        evictBackgroundSurfaces(using: splitTreesByPath)
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
        evictBackgroundSurfaces(using: splitTreesByPath)
    }

    func trim(using splitTreesByPath: [String: SplitTree]) {
        prune(using: splitTreesByPath)
        evictBackgroundSurfaces(using: splitTreesByPath)
    }

    private func prune(using splitTreesByPath: [String: SplitTree]) {
        lru.removeAll { !splitTreesByPath.keys.contains($0) }
    }

    private func evictBackgroundSurfaces(using splitTreesByPath: [String: SplitTree]) {
        while lru.count > capacity {
            // Open windows can temporarily exceed the background cache limit.
            guard let index = lru.lastIndex(where: { !isPresented($0) }) else { return }
            let evictedPath = lru.remove(at: index)
            guard let tree = splitTreesByPath[evictedPath] else { continue }
            for leaf in tree.allLeaves {
                onEvict(leaf)
            }
        }
    }
}
