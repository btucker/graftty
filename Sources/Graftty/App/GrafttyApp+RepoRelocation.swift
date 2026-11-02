import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// Each waiter has its own stream so cancelling one creation cannot cancel
/// the completion signal for other creations waiting on the same relocation.
@MainActor
private final class RepoRelocationCompletion {
    private var succeeded: Bool?
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    func wait() async throws {
        if succeeded == nil {
            let waiterID = UUID()
            let (events, continuation) = AsyncStream<Void>.makeStream()
            waiters[waiterID] = continuation
            defer { waiters[waiterID] = nil }
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        try Task.checkCancellation()
        guard succeeded == true else {
            throw RepoRelocationInterrupted()
        }
    }

    func finish(succeeded: Bool) {
        self.succeeded = succeeded
        for waiter in waiters.values { waiter.finish() }
        waiters.removeAll()
    }
}

private struct RepoRelocationInterrupted: LocalizedError {
    var errorDescription: String? { "Repository relocation did not complete. Retry worktree creation after resolving the repository location." }
}

@MainActor
private final class RepoRelocationState {
    var revision = 0
    var lastFailureRevision = 0
    var active: [UUID: RepoRelocationCompletion] = [:]
}

extension GrafttyApp {
    @MainActor
    private static var repoRelocations: [UUID: RepoRelocationState] = [:]

    @MainActor
    static func repoRelocationRevision(_ repoID: UUID) -> Int {
        repoRelocations[repoID]?.revision ?? 0
    }

    @MainActor
    static func checkRepoRelocationFailures(_ repoID: UUID, since revision: Int) throws {
        if let state = repoRelocations[repoID], state.lastFailureRevision > revision {
            throw RepoRelocationInterrupted()
        }
    }

    @MainActor
    static func isRelocatingRepo(_ repoID: UUID) -> Bool {
        !(repoRelocations[repoID]?.active.isEmpty ?? true)
    }

    @MainActor
    static func waitForRepoRelocations(_ repoID: UUID) async throws {
        while let completion = repoRelocations[repoID]?.active.values.first {
            try await completion.wait()
        }
        try Task.checkCancellation()
    }

    /// Pre-pass for `reconcileOnLaunch` implementing LAYOUT-4.6 (bookmark
    /// resolution at launch) and LAYOUT-4.9 (backfill mint for pre-upgrade
    /// entries without bookmarks).
    ///
    /// For each `RepoEntry`:
    /// - If it has a bookmark, resolve it. If the resolved path differs
    ///   from the stored `path`, run the relocate cascade. If the
    ///   bookmark resolves to the same path but is stale, re-mint.
    /// - If it has no bookmark and the stored `path` exists on disk, mint
    ///   one in place (migration from pre-LAYOUT-4.5 state.json).
    ///
    /// Runs before any `WorktreeMonitor.watch*` calls in `startup()`
    /// would have armed watchers at stale paths; by the time
    /// `reconcileOnLaunch`'s own discover loop runs, each `RepoEntry` is
    /// already at its current-on-disk location.
    ///
    /// Static so the bridge (`WorktreeMonitorBridge`) can reach it
    /// without holding a reference to `GrafttyApp` (a SwiftUI App
    /// struct). Dependencies are threaded in as params.
    @MainActor
    static func resolveRepoLocations(
        appState: Binding<AppState>,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        remoteBranchStore: RemoteBranchStore,
        discover: @MainActor (RepoEntry) async throws -> [DiscoveredWorktree] = { try await WorktreeDiscovery.discover(repo: $0) }
    ) async {
        let repoIDs = appState.wrappedValue.repos.map(\.id)
        for repoID in repoIDs {
            guard let repoIdx = appState.wrappedValue.repos.firstIndex(where: { $0.id == repoID }) else { continue }
            let repo = appState.wrappedValue.repos[repoIdx]
            if let bookmark = repo.bookmark {
                do {
                    let resolved = try RepoBookmark.resolve(bookmark)
                    if resolved.url.path != repo.path {
                        await relocateRepo(
                            appState: appState,
                            worktreeMonitor: worktreeMonitor,
                            statsStore: statsStore,
                            prStatusStore: prStatusStore,
                            remoteBranchStore: remoteBranchStore,
                            repoIdx: repoIdx,
                            newURL: resolved.url,
                            isStale: resolved.isStale,
                            discover: discover
                        )
                    } else if resolved.isStale {
                        // Same path, but the bookmark is stale (cross-
                        // volume move, APFS firmlink resolution). Re-mint
                        // so next launch's resolve is fast and we don't
                        // accumulate staleness.
                        appState.wrappedValue.repos[repoIdx].bookmark = try? RepoBookmark.mint(atPath: repo.path)
                    }
                } catch {
                    NSLog("[Graftty] resolveRepoLocations: bookmark resolve failed for %@: %@",
                          repo.path, String(describing: error))
                }
            } else if FileManager.default.fileExists(atPath: repo.path) {
                // LAYOUT-4.9: entry decoded from a pre-LAYOUT-4.5
                // state.json has no bookmark. The stored path resolves
                // on disk, so mint a fresh bookmark from it — subsequent
                // renames/moves will then be recoverable automatically.
                if let fresh = try? RepoBookmark.mint(atPath: repo.path) {
                    appState.wrappedValue.repos[repoIdx].bookmark = fresh
                }
            }
        }
    }

    /// Orchestrator for LAYOUT-4.8 — enacts the relocate decisions
    /// produced by `RepoRelocator` against the live model, watchers, and
    /// caches. Called from two entry points: the launch-time pre-pass
    /// (`resolveRepoLocations`) and the
    /// `WorktreeMonitor.worktreeMonitorDidDetectDeletion` FSEvents hook
    /// on `WorktreeMonitorBridge` (LAYOUT-4.7).
    ///
    /// Ordering matters: watcher stop + cache clear MUST happen before
    /// the `appState.repos[repoIdx].path` assignment, otherwise later
    /// `stopWatching(repoPath:)` / `clear(worktreePath:)` calls would
    /// see the new path and the old-path watchers + cache entries would
    /// leak (GIT-3.11 / GIT-3.13).
    ///
    /// Static so the bridge can reach it without capturing the SwiftUI
    /// `GrafttyApp` struct. All live deps (appState binding, watcher,
    /// stores) are threaded in as params.
    @MainActor
    static func relocateRepo(
        appState: Binding<AppState>,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        remoteBranchStore: RemoteBranchStore,
        repoIdx: Int,
        newURL: URL,
        isStale: Bool,
        discover: @MainActor (RepoEntry) async throws -> [DiscoveredWorktree] = { try await WorktreeDiscovery.discover(repo: $0) },
        repair: @MainActor (String, [String]) async throws -> Void = { try await GitWorktreeRepair.repair(repoPath: $0, worktreePaths: $1) }
    ) async {
        // Guard: the caller may have suspended on an `await` between the
        // index lookup and here; if the repo vanished in the meantime
        // (e.g. concurrent Remove Repository), skip silently.
        guard appState.wrappedValue.repos.indices.contains(repoIdx) else {
            NSLog("[Graftty] relocateRepo: repoIdx %d out of range after suspension", repoIdx)
            return
        }

        let repoID = appState.wrappedValue.repos[repoIdx].id
        let oldRepoPath = appState.wrappedValue.repos[repoIdx].path
        let newRepoPath = newURL.path

        // (a) Abort if the resolved folder is no longer a git repo.
        // A rename into a non-git directory (e.g. bookmark survived a
        // cross-volume move that clobbered `.git`) has no recovery path;
        // falling through to the stale transition is correct.
        do {
            let detection = try GitRepoDetector.detect(path: newRepoPath)
            guard case .repoRoot = detection else {
                NSLog("[Graftty] relocateRepo: resolved URL is not a repo root (detection=%@): %@",
                      String(describing: detection), newRepoPath)
                return
            }
        } catch {
            NSLog("[Graftty] relocateRepo: detect failed at %@: %@",
                  newRepoPath, String(describing: error))
            return
        }

        let relocationID = UUID()
        let completion = RepoRelocationCompletion()
        let relocationState = repoRelocations[repoID] ?? RepoRelocationState()
        repoRelocations[repoID] = relocationState
        relocationState.revision += 1
        relocationState.active[relocationID] = completion
        var succeeded = false
        defer {
            // Remove only this operation; a newer relocation may still be active.
            relocationState.active[relocationID] = nil
            relocationState.revision += 1
            if !succeeded { relocationState.lastFailureRevision = relocationState.revision }
            // Keep the revision after completion: a discovery may still be
            // suspended with paths captured before this relocation ended.
            completion.finish(succeeded: succeeded)
        }

        // (b) Re-mint stale bookmark from the new path so future
        // resolves don't pay the staleness cost.
        if isStale, let fresh = try? RepoBookmark.mint(atPath: newRepoPath) {
            appState.wrappedValue.repos[repoIdx].bookmark = fresh
        }

        // (c) + (d) Stop repo-level and per-worktree watchers and clear
        // per-old-path caches before any mutation of
        // `appState.repos[repoIdx].path` — `stopWatching` matches
        // watcher keys by the repoPath we pass in, not by the repo's
        // current model value, and caches keyed by the old path would
        // bleed into carried-forward worktrees. Shared with Remove
        // Repository via `RepoTeardown`.
        RepoTeardown.stopWatchersAndClearCaches(
            repo: appState.wrappedValue.repos[repoIdx],
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            remoteBranchStore: remoteBranchStore
        )

        // (e) Snapshot the pre-relocate repo for the pure decision
        // function, then apply the repo-level path/displayName update.
        // The snapshot is load-bearing: the decision reads old paths to
        // compute rewrites, and we're about to clobber them in the
        // model.
        let pre = appState.wrappedValue.repos[repoIdx]
        appState.wrappedValue.repos[repoIdx].path = newRepoPath
        appState.wrappedValue.repos[repoIdx].displayName = newURL.lastPathComponent

        // (f) Discover at the new location. On failure, leave the
        // repo.path updated but worktrees untouched — the per-worktree
        // stale transitions will happen naturally on the next
        // reconcile / FSEvents delete, so this is a recoverable state.
        var discovered: [DiscoveredWorktree]
        do {
            discovered = try await discover(appState.wrappedValue.repos[repoIdx])
        } catch {
            NSLog("[Graftty] relocateRepo: discover failed at %@: %@",
                  newRepoPath, String(describing: error))
            // The repo path (and bookmark) already moved; keep it on restart.
            Self.persistAppState(appState.wrappedValue)
            return
        }

        // Every suspension can remove, reorder, or relocate this entry.
        // An offset from before discovery no longer identifies the repo.
        func currentIndex() -> Int? {
            guard !Task.isCancelled else { return nil }
            return appState.wrappedValue.repos.firstIndex { $0.id == repoID && $0.path == newRepoPath }
        }
        guard currentIndex() != nil else { return }

        // (g) Ask the pure decision function whether a repair is needed.
        // If yes, run `git worktree repair` (which rewrites the `gitdir:`
        // files of linked worktrees whose paths moved) and re-discover.
        let firstDecision = RepoRelocator.decide(
            repo: pre,
            newRepoPath: newRepoPath,
            discovered: discovered,
            selectedWorktreePath: appState.wrappedValue.selectedWorktreePath
        )
        let finalDecision: RepoRelocator.Decision
        if firstDecision.needsRepair {
            do {
                try await repair(newRepoPath, firstDecision.repairCandidatePaths)
                guard let currentRepoIdx = currentIndex() else { return }
                discovered = try await discover(appState.wrappedValue.repos[currentRepoIdx])
            } catch {
                NSLog("[Graftty] relocateRepo: repair/rediscover failed at %@: %@",
                      newRepoPath, String(describing: error))
                // Fall through with the current `discovered` snapshot;
                // unmatched pre-worktrees will go stale and the user can
                // dismiss them manually.
            }
            finalDecision = RepoRelocator.decidePostRepair(
                repo: pre,
                newRepoPath: newRepoPath,
                discovered: discovered,
                selectedWorktreePath: appState.wrappedValue.selectedWorktreePath
            )
        } else {
            finalDecision = firstDecision
        }

        guard let repoIdx = currentIndex() else { return }

        // (h) Merge the snapshot's path decisions into live worktrees by ID.
        // Discovery and repair may have suspended while panes, order, or
        // membership changed; copying `pre` here would undo those edits.
        let currentRepo = appState.wrappedValue.repos[repoIdx]
        let selectedID = currentRepo.worktrees.first {
            $0.path == appState.wrappedValue.selectedWorktreePath
        }?.id
        appState.wrappedValue.repos[repoIdx].worktrees = RepoRelocator.relocatedWorktrees(
            repo: currentRepo, decision: finalDecision, discovered: discovered
        )

        // (i) Resolve the latest selection by its current identity. A new row
        // can reuse a removed row's path without inheriting its stale decision.
        if let carried = finalDecision.carriedForward.first(where: { $0.existingID == selectedID }) {
            appState.wrappedValue.selectedWorktreePath = carried.newPath
        } else if finalDecision.goneStale.contains(where: { $0.existingID == selectedID }) {
            appState.wrappedValue.selectedWorktreePath = nil
        }

        // (j) Install fresh watchers at the new paths. Matches
        // `startup()`'s initial watcher-install loop exactly so the
        // post-relocate watcher graph is indistinguishable from a
        // from-scratch launch at the new location.
        worktreeMonitor.installRepoWatchers(repo: appState.wrappedValue.repos[repoIdx])
        remoteBranchStore.refresh(repoPath: newRepoPath)
        Self.persistAppState(appState.wrappedValue)
        succeeded = true

        NSLog("[Graftty] relocateRepo: %@ → %@", oldRepoPath, newRepoPath)
    }
}
