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
        discovered: [DiscoveredWorktree]
    ) -> Result {
        let existingPaths = Set(existing.map(\.path))
        let discoveredPaths = Set(discovered.map(\.path))
        let branchByPath = Dictionary(uniqueKeysWithValues: discovered.map { ($0.path, $0.branch) })

        var merged: [WorktreeEntry] = []
        var newlyStale: [WorktreeEntry] = []
        var resurrected: [WorktreeEntry] = []

        for wt in existing {
            var copy = wt
            if !discoveredPaths.contains(wt.path) {
                // `.creating` placeholders inserted by `AddWorktreeFlow`
                // can race with this reconcile when FSEvents on
                // `.git/worktrees/` fires *before* git finishes writing
                // the admin dir (or hasn't even gotten there yet — git's
                // pre-commit/post-checkout hooks may take seconds). The
                // placeholder isn't on disk yet, so a naive transition
                // would briefly flip our spinning row to `.stale`.
                // `AddWorktreeFlow` owns the placeholder's lifecycle —
                // skip the stale transition for those entries and let
                // the flow promote them to `.running` (or remove them
                // outright on git failure).
                if wt.state != .stale && wt.state != .creating {
                    copy.state = .stale
                    newlyStale.append(copy)
                }
            } else {
                if wt.state == .stale {
                    copy.state = .closed
                    resurrected.append(copy)
                }
                if let b = branchByPath[wt.path] { copy.branch = b }
            }
            merged.append(copy)
        }

        let newlyAdded = discovered
            .filter { !existingPaths.contains($0.path) }
            .map { WorktreeEntry(path: $0.path, branch: $0.branch) }

        merged.append(contentsOf: newlyAdded)

        return Result(
            merged: merged,
            newlyAdded: newlyAdded,
            newlyStale: newlyStale,
            resurrected: resurrected
        )
    }
}
