import Foundation

/// Pure decision function for the repo-relocate cascade (LAYOUT-4.8).
/// Takes a snapshot of the pre-relocate state plus the post-discovery
/// view of the filesystem and returns a list of discrete decisions the
/// caller then enacts:
///
/// - which existing `WorktreeEntry`s carry forward (and to which new
///   paths), preserving `id` / `splitTree` / `state` / attention state;
/// - which existing entries go `.stale` (git no longer lists them even
///   after optional `git worktree repair`);
/// - whether `git worktree repair` should run and for which paths;
/// - how to update `selectedWorktreePath` to track the move.
///
/// Keeping this pure means the cascade's branching is unit-testable
/// without plumbing through `MainWindow`, `WorktreeMonitor`,
/// `PRStatusStore`, etc. The orchestrator (GrafttyApp / MainWindow) then
/// enacts the decisions by calling watcher / cache / model APIs.
public enum RepoRelocator {

    public struct CarryForward: Equatable {
        public let existingID: UUID
        public let newPath: String
        public let branch: String
    }

    public struct Stale: Equatable {
        public let existingID: UUID
        public let oldPath: String
        public let branch: String
    }

    public struct Decision: Equatable {
        public let needsRepair: Bool
        public let repairCandidatePaths: [String]
        public let carriedForward: [CarryForward]
        public let goneStale: [Stale]
        public let newSelectedWorktreePath: String?
    }

    /// Applies a final relocation decision, preserving saved order and each existing entry's state.
    public static func relocatedWorktrees(
        repo: RepoEntry, decision: Decision, discovered: [DiscoveredWorktree], now: Date = Date()
    ) -> [WorktreeEntry] {
        let carriedByID = Dictionary(uniqueKeysWithValues: decision.carriedForward.map { ($0.existingID, $0) })
        let staleIDs = Set(decision.goneStale.map(\.existingID))
        var worktrees: [WorktreeEntry] = []
        for var existing in repo.worktrees {
            if let carried = carriedByID[existing.id] {
                existing.path = carried.newPath
                existing.branch = carried.branch
            } else if staleIDs.contains(existing.id) {
                existing.markStale(at: now)
            } else {
                continue
            }
            worktrees.append(existing)
        }
        let carriedPaths = Set(decision.carriedForward.map(\.newPath))
        for entry in discovered where !carriedPaths.contains(entry.path) {
            worktrees.append(WorktreeEntry(path: entry.path, branch: entry.branch))
        }
        return WorktreeOrdering.staleLast(worktrees)
    }

    /// First-pass decision, before any `git worktree repair` has run.
    /// If the post-discovery result is missing any previously-known
    /// linked worktree, `needsRepair` is true and the caller should run
    /// `GitWorktreeRepair.repair(...)` at `repairCandidatePaths`, then
    /// re-discover and call `decidePostRepair`.
    public static func decide(
        repo: RepoEntry,
        newRepoPath: String,
        discovered: [DiscoveredWorktree],
        selectedWorktreePath: String?
    ) -> Decision {
        // A pre-existing worktree is "missing" (i.e., suggests git lost
        // track of it after the repo folder moved) only if *no* discovered
        // entry references its branch. A branch match at a different path
        // means git still knows about the worktree — the user just moved
        // it to a different leaf, which the buildDecision step handles by
        // matching on branch.
        let discoveredBranches = Set(discovered.map(\.branch))
        let missing = expectedNewPaths(
            existing: repo,
            oldRepoPath: repo.path,
            newRepoPath: newRepoPath
        ).filter { expected in
            let existing = repo.worktrees[expected.existingIndex]
            return !discoveredBranches.contains(existing.branch)
        }

        if !missing.isEmpty {
            return Decision(
                needsRepair: true,
                repairCandidatePaths: missing.map(\.newPath),
                carriedForward: [],
                goneStale: [],
                newSelectedWorktreePath: selectedWorktreePath // unchanged until post-repair
            )
        }
        return buildDecision(
            repo: repo,
            discovered: discovered,
            selectedWorktreePath: selectedWorktreePath
        )
    }

    /// Second-pass decision, after `git worktree repair` has run. Any
    /// existing entry without a branch match in `discovered` goes stale.
    public static func decidePostRepair(
        repo: RepoEntry,
        newRepoPath: String,
        discovered: [DiscoveredWorktree],
        selectedWorktreePath: String?
    ) -> Decision {
        buildDecision(
            repo: repo,
            discovered: discovered,
            selectedWorktreePath: selectedWorktreePath
        )
    }

    private struct ExpectedPath {
        let existingIndex: Int
        let newPath: String
    }

    /// Rewrite each existing worktree path's old-repo prefix to new-repo
    /// prefix. Paths that don't share the old prefix are returned
    /// unchanged (user moved a worktree individually — caught downstream
    /// as a branch mismatch).
    private static func expectedNewPaths(
        existing: RepoEntry,
        oldRepoPath: String,
        newRepoPath: String
    ) -> [ExpectedPath] {
        existing.worktrees.enumerated().map { idx, wt in
            if wt.path == oldRepoPath {
                return ExpectedPath(existingIndex: idx, newPath: newRepoPath)
            }
            if wt.path.hasPrefix(oldRepoPath + "/") {
                let suffix = String(wt.path.dropFirst(oldRepoPath.count))
                return ExpectedPath(existingIndex: idx, newPath: newRepoPath + suffix)
            }
            return ExpectedPath(existingIndex: idx, newPath: wt.path)
        }
    }

    private static func buildDecision(
        repo: RepoEntry,
        discovered: [DiscoveredWorktree],
        selectedWorktreePath: String?
    ) -> Decision {
        var carried: [CarryForward] = []
        var stale: [Stale] = []
        var matchedIDs = Set<UUID>()

        for d in discovered {
            if let existing = pickExistingMatch(
                for: d,
                from: repo.worktrees,
                alreadyMatched: matchedIDs
            ) {
                carried.append(CarryForward(
                    existingID: existing.id,
                    newPath: d.path,
                    branch: d.branch
                ))
                matchedIDs.insert(existing.id)
            }
            // Discovered entries with no branch match are fresh worktrees
            // the caller appends verbatim — surfaced through the
            // orchestrator's apply step.
        }

        for wt in repo.worktrees where !matchedIDs.contains(wt.id) {
            stale.append(Stale(existingID: wt.id, oldPath: wt.path, branch: wt.branch))
        }

        let newSelection: String?
        if let sel = selectedWorktreePath,
           let match = carried.first(where: { cf in
               repo.worktrees.first(where: { $0.id == cf.existingID })?.path == sel
           }) {
            newSelection = match.newPath
        } else if let sel = selectedWorktreePath,
                  stale.contains(where: { $0.oldPath == sel }) {
            newSelection = nil
        } else {
            newSelection = selectedWorktreePath
        }

        return Decision(
            needsRepair: false,
            repairCandidatePaths: [],
            carriedForward: carried,
            goneStale: stale,
            newSelectedWorktreePath: newSelection
        )
    }

    /// Match a discovered worktree to an existing `WorktreeEntry`, preserving
    /// `id` continuity across a relocate. Primary match is by `branch` (stable
    /// within a repo for a named branch). Synthetic labels git emits for
    /// headless states — `"(detached)"`, `"(bare)"` — aren't unique, so for
    /// those we match by path suffix as a tiebreaker. `alreadyMatched` skips
    /// entries a prior iteration already claimed, so two detached-HEAD
    /// discovered entries in the same repo don't both bind to the first
    /// existing row.
    private static func pickExistingMatch(
        for discovered: DiscoveredWorktree,
        from existing: [WorktreeEntry],
        alreadyMatched: Set<UUID>
    ) -> WorktreeEntry? {
        let candidates = existing.filter {
            $0.branch == discovered.branch && !alreadyMatched.contains($0.id)
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        // Synthetic label (`(detached)` / `(bare)`) or duplicate-branch edge:
        // fall back to path-suffix matching so we don't silently orphan a
        // real entry. Match by last path component.
        let discoveredLeaf = URL(fileURLWithPath: discovered.path).lastPathComponent
        if let byLeaf = candidates.first(where: {
            URL(fileURLWithPath: $0.path).lastPathComponent == discoveredLeaf
        }) {
            return byLeaf
        }
        return candidates.first
    }
}
