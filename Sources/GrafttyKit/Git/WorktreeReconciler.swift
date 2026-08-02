import Foundation

/// Pure policy for reconciling a saved worktree list against the output of
/// `git worktree list --porcelain`. Callers (GrafttyApp's two reconcile
/// sites) wrap this with their side effects (FSEvents watch registration,
/// stats/PR store seeding, etc.).
///
/// Rules (per §4.3 / GIT-3.x):
///   - Any `existing` whose path isn't in `discovered` transitions to `.stale`.
///   - Any `existing` marked `.stale` whose path IS in `discovered` transitions
///     to `.closed` (GIT-3.7 resurrection — previously this never happened,
///     so a transiently-missing directory left the entry stuck stale forever).
///   - Non-stale entries still in `discovered` keep their state but adopt
///     the latest branch label.
///   - Any `discovered` path not in `existing` is appended as a `.closed` entry.
public enum WorktreeReconciler {

    public struct Result: Equatable {
        public let merged: [WorktreeEntry]
        public let newlyAdded: [WorktreeEntry]
        public let newlyStale: [WorktreeEntry]
        public let resurrected: [WorktreeEntry]
    }

    public static func reconcile(
        existing: [WorktreeEntry],
        discovered: [DiscoveredWorktree],
        now: Date = Date()
    ) -> Result {
        // A `prunable` porcelain record is leftover Git admin metadata for
        // a worktree whose directory is gone, not a live worktree. Treat it
        // exactly like absence so launch reconciliation agrees with the
        // directory-deletion watcher (GIT-3.3).
        let liveDiscovered = discovered.filter { !$0.isPrunable }
        let existingPaths = Set(existing.map(\.path))
        let discoveredPaths = Set(liveDiscovered.map(\.path))
        let branchByPath = Dictionary(uniqueKeysWithValues: liveDiscovered.map { ($0.path, $0.branch) })

        var merged: [WorktreeEntry] = []
        var newlyStale: [WorktreeEntry] = []
        var resurrected: [WorktreeEntry] = []

        for wt in existing {
            var copy = wt
            if !discoveredPaths.contains(wt.path) {
                // In-flight placeholders are owned by their flows
                // (`AddWorktreeFlow` / `DeleteWorktreeFlow`); an
                // FSEvents-driven reconcile must not transition them
                // to `.stale` mid-flight — only the owning flow may
                // clear the placeholder.
                if wt.state != .stale && !wt.state.isInFlight {
                    copy.markStale(at: now)
                    newlyStale.append(copy)
                } else if wt.state == .stale && wt.staleSince == nil {
                    // Legacy persisted stale entries predate the timestamp.
                    // Start their grace period only after a successful
                    // discovery confirms they are still absent.
                    copy.markStale(at: now)
                }
            } else {
                if wt.state == .stale {
                    copy.state = .closed
                    copy.staleSince = nil
                    resurrected.append(copy)
                }
                if let b = branchByPath[wt.path] { copy.branch = b }
            }
            merged.append(copy)
        }

        let newlyAdded = liveDiscovered
            .filter { !existingPaths.contains($0.path) }
            .map { WorktreeEntry(path: $0.path, branch: $0.branch) }

        merged.append(contentsOf: newlyAdded)
        merged = WorktreeOrdering.staleLast(merged)

        return Result(
            merged: merged,
            newlyAdded: newlyAdded,
            newlyStale: newlyStale,
            resurrected: resurrected
        )
    }
}
