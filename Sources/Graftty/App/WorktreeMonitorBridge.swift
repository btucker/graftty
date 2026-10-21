import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

@MainActor
final class WorktreeMonitorBridge: WorktreeMonitorDelegate {
    typealias DiscoverWorktrees = @Sendable (
        _ repo: RepoEntry
    ) async throws -> [DiscoveredWorktree]

    nonisolated static let defaultDiscoverWorktrees: DiscoverWorktrees = { repo in
        try await WorktreeDiscovery.discover(repo: repo)
    }

    /// Tests substitute an immediate-fire recorder so a CI MainActor
    /// starvation episode can't push the wall-clock follow-up sleep
    /// past the test's `waitUntil` window.
    typealias FollowUpScheduler = @Sendable (
        _ delay: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) -> Void

    nonisolated static let defaultFollowUpScheduler: FollowUpScheduler = { delay, work in
        Task.detached {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await work()
        }
    }

    let appState: Binding<AppState>
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let remoteBranchStore: RemoteBranchStore
    private let discoverWorktrees: DiscoverWorktrees
    private let originRefPRFollowUpScheduler: FollowUpScheduler

    init(
        appState: Binding<AppState>,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        remoteBranchStore: RemoteBranchStore,
        discoverWorktrees: @escaping DiscoverWorktrees = WorktreeMonitorBridge.defaultDiscoverWorktrees,
        originRefPRFollowUpScheduler: @escaping FollowUpScheduler = WorktreeMonitorBridge.defaultFollowUpScheduler
    ) {
        self.appState = appState
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
        self.remoteBranchStore = remoteBranchStore
        self.discoverWorktrees = discoverWorktrees
        self.originRefPRFollowUpScheduler = originRefPRFollowUpScheduler
    }

    /// Called when `.git/worktrees/` changes (new worktree added, existing
    /// one removed externally). After reconciling appState, refresh stats
    /// for every non-stale worktree in the repo — new worktrees need their
    /// initial stats, removed ones will be marked stale (and stats cleared
    /// by `worktreeMonitorDidDetectDeletion`).
    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        let discover = discoverWorktrees
        // `git worktree list --porcelain` is a subprocess wait. Awaiting the
        // now-async `GitWorktreeDiscovery.discover` yields the main actor
        // during the wait so ghostty keystrokes aren't delayed (prior
        // manifestation: intermittent ~1s input/render hangs under fs/
        // indexing pressure).
        Task { @MainActor in
            guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }
            let discovered: [DiscoveredWorktree]
            do {
                discovered = try await discover(repo)
            } catch {
                NSLog("[Graftty] worktreeMonitorDidDetectChange: discover failed for %@: %@",
                      repoPath, String(describing: error))
                return
            }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else { return }

            let previousWorktrees = binding.wrappedValue.repos[repoIdx].worktrees
            let result = WorktreeReconciler.reconcile(
                existing: previousWorktrees,
                discovered: discovered
            )
            binding.wrappedValue.repos[repoIdx].worktrees = result.merged
            if result.merged != previousWorktrees {
                // This delegate remains active with no visible window; the
                // WindowGroup's `.onChange` observer may not exist then.
                GrafttyApp.persistAppState(binding.wrappedValue)
            }

            // GIT-3.13 / GIT-3.15: clear cached stats/PR AND drop the
            // worktree's watchers on every stale transition, matching
            // the FSEvents-deletion path. Zombie watchers bound to
            // the reaped inode would otherwise block same-path
            // resurrection from re-arming cleanly.
            for wt in result.newlyStale {
                store.clear(worktreePath: wt.path)
                prStore.clear(worktreePath: wt.path)
                monitor.stopWatchingWorktree(wt.path)
            }

            // watchWorktreePath / watchHeadRef / watchWorktreeContents are
            // idempotent, so registering for the whole repo is cheap; this
            // is how newly-discovered worktrees (external `git worktree
            // add`) start getting HEAD + working-tree tracking without an
            // app restart. Includes resurrected entries.
            for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state.hasOnDiskWorktree {
                monitor.watchWorktreePath(wt.path)
                monitor.watchHeadRef(worktreePath: wt.path, repoPath: repoPath)
                monitor.watchWorktreeContents(worktreePath: wt.path)
            }

            // Existing worktrees' stats are driven by their own HEAD and
            // origin-ref callbacks plus the polling fallback, so a
            // `.git/worktrees/` directory tick only needs to seed stats
            // for new entries.
            for wt in result.newlyAdded where wt.state == .running {
                store.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        let remoteBranchStore = remoteBranchStore
        Task { @MainActor in
            let previousState = binding.wrappedValue
            // LAYOUT-4.7: before marking the worktree stale, see if the
            // owning repo has a bookmark and whether it now resolves to
            // a different path. If it does, run the relocate cascade —
            // this catches the "user renamed the repo folder in Finder
            // while Graftty was running" case. FSEvents delivered a
            // deletion on the old path; the bookmark points at the new
            // one. Running the cascade here means the user never sees
            // the yellow stale state for a renamed repo.
            if let (repoIdx, _) = binding.wrappedValue.indices(forWorktreePath: worktreePath),
               let bookmark = binding.wrappedValue.repos[repoIdx].bookmark {
                do {
                    let resolved = try RepoBookmark.resolve(bookmark)
                    if resolved.url.path != binding.wrappedValue.repos[repoIdx].path {
                        await GrafttyApp.relocateRepo(
                            appState: binding,
                            worktreeMonitor: monitor,
                            statsStore: store,
                            prStatusStore: prStore,
                            remoteBranchStore: remoteBranchStore,
                            repoIdx: repoIdx,
                            newURL: resolved.url,
                            isStale: resolved.isStale
                        )
                        // Relocate ran — worktrees either moved with
                        // it or went stale via RepoRelocator
                        // decisions. Skip the existing unconditional
                        // stale path below so we don't double-clear
                        // caches or re-stop already-stopped watchers.
                        return
                    }
                } catch {
                    NSLog("[Graftty] worktreeMonitorDidDetectDeletion: bookmark resolve failed: %@",
                          String(describing: error))
                    // fall through to the existing stale path
                }
            }

            if let indices = binding.wrappedValue.indices(forWorktreePath: worktreePath) {
                let repoID = binding.wrappedValue.repos[indices.repo].id
                if binding.wrappedValue.repos[indices.repo].worktrees[indices.worktree].state != .stale {
                    binding.wrappedValue.repos[indices.repo].worktrees[indices.worktree].markStale()
                } else if binding.wrappedValue.repos[indices.repo]
                    .worktrees[indices.worktree].staleSince == nil {
                    binding.wrappedValue.repos[indices.repo]
                        .worktrees[indices.worktree].markStale()
                }
                binding.wrappedValue.moveStaleWorktreesToBottom(inRepoID: repoID)
            }
            store.clear(worktreePath: worktreePath)
            prStore.clear(worktreePath: worktreePath)
            // `GIT-3.15`: drop the path / head / content watchers for
            // the deleted worktree so a subsequent `git worktree add`
            // at the same path (detected by the repo-level watcher)
            // re-arms fresh fds on the new inode, rather than the
            // reconciler's "idempotent" re-register skipping over
            // zombie fds bound to the reaped inode.
            monitor.stopWatchingWorktree(worktreePath)
            if binding.wrappedValue != previousState {
                GrafttyApp.persistAppState(binding.wrappedValue)
            }
        }
    }

    /// Fires when any remote-tracking ref under
    /// `<repoPath>/.git/logs/refs/remotes/origin/` moves — i.e. a
    /// `git push` or `git fetch` landed. Covers the `gh pr create`
    /// flow, which pushes then creates the PR via API without touching
    /// local HEAD. Refreshes divergence for the repo's running
    /// worktrees immediately, then drives the remote-branch and PR
    /// refresh. The polling tick remains a fallback for a coalesced or
    /// missed FSEvent.
    nonisolated func worktreeMonitorDidDetectOriginRefChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        let store = statsStore
        let remoteBranchStore = remoteBranchStore
        Task { @MainActor [self] in
            guard let repo = binding.wrappedValue.repos.first(where: {
                $0.path == repoPath && $0.isGitTracked
            }) else { return }
            store.refreshAutoTracking(repoPath: repoPath)
            // Graftty's own periodic fetch also moves origin refs. Limit
            // this repo-wide signal to running rows so it doesn't turn
            // into recurring work proportional to closed history.
            for wt in repo.worktrees where wt.state == .running {
                store.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
            }
            remoteBranchStore.refresh(repoPath: repoPath) { [weak self = self] in
                self?.refreshPushedPRs(repoPath: repoPath)
                self?.scheduleOriginRefPRFollowUps(repoPath: repoPath)
            }
        }
    }

    private func refreshPushedPRs(repoPath: String) {
        guard let repo = appState.wrappedValue.repos.first(where: { $0.path == repoPath }) else { return }
        for wt in repo.worktrees where wt.state.hasOnDiskWorktree {
            guard remoteBranchStore.hasRemote(repoPath: repoPath, branch: wt.branch) else { continue }
            prStatusStore.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
        }
    }

    private func scheduleOriginRefPRFollowUps(repoPath: String) {
        // Detached so a starved MainActor (heavy app startup, CI
        // test parallelism) can't push the sleep out by many
        // seconds; only the eventual `refreshPushedPRs` hops back.
        let delays: [Duration] = [.seconds(1), .seconds(5)]
        for delay in delays {
            originRefPRFollowUpScheduler(delay) { [weak self] in
                await self?.refreshPushedPRs(repoPath: repoPath)
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        let prStore = prStatusStore
        let remoteBranchStore = remoteBranchStore
        let discover = discoverWorktrees
        // Branch changes fire in bursts (rebase, interactive checkout), so
        // `GitWorktreeDiscovery.discover`'s subprocess wait must yield the
        // main actor — the async version does that naturally. Scope the
        // discover call to the owning repo only, not every tracked repo.
        Task { @MainActor in
            guard let repo = binding.wrappedValue.repos.first(where: { repo in
                repo.isGitTracked && repo.worktrees.contains(where: { $0.path == worktreePath })
            }) else { return }
            let repoPath = repo.path
            let discovered: [DiscoveredWorktree]
            do {
                discovered = try await discover(repo)
            } catch {
                NSLog("[Graftty] worktreeMonitorDidDetectBranchChange: discover failed for %@: %@",
                      repoPath, String(describing: error))
                return
            }
            guard let match = discovered.first(where: { $0.path == worktreePath }) else { return }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }),
                  let wtIdx = binding.wrappedValue.repos[repoIdx].worktrees.firstIndex(where: { $0.path == worktreePath }) else { return }
            binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
            store.refreshAutoTracking(repoPath: repoPath)
            if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state.hasOnDiskWorktree {
                store.refresh(worktreePath: worktreePath, repoPath: repoPath, branch: match.branch)
            }
            prStore.clear(worktreePath: worktreePath)
            remoteBranchStore.refresh(repoPath: repoPath) {
                guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }),
                      let wt = repo.worktrees.first(where: {
                          $0.path == worktreePath && $0.state.hasOnDiskWorktree
                      })
                else { return }
                prStore.refresh(worktreePath: worktreePath, repoPath: repoPath, branch: wt.branch)
            }
        }
    }
}
