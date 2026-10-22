import SwiftUI
import AppKit
import GrafttyCommandUI
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

extension GrafttyApp {
    func reconcileOnLaunch(
        onComplete: @MainActor @escaping () -> Void
    ) {
        let binding = $appState
        let statsStore = services.statsStore
        let prStatusStore = services.prStatusStore
        let remoteBranchStore = services.remoteBranchStore
        let worktreeMonitor = services.worktreeMonitor
        let terminalManager = self.terminalManager
        Task { @MainActor in
            defer { onComplete() }
            // LAYOUT-4.6 / LAYOUT-4.9: resolve bookmarks and run any
            // relocate cascades BEFORE the discover+reconcile loop below.
            // If a repo moved in Finder between runs, this fixes up its
            // path (and per-worktree paths) so the subsequent discover
            // uses the right repoPath and the reconcile doesn't flag
            // every worktree as newly-stale.
            await Self.resolveRepoLocations(
                appState: binding,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                remoteBranchStore: remoteBranchStore
            )

            for repoPath in binding.wrappedValue.repos.map(\.path) {
                guard let repo = binding.wrappedValue.repos.first(where: { $0.path == repoPath }) else { continue }
                let discovered: [DiscoveredWorktree]
                do {
                    discovered = try await WorktreeDiscovery.discover(repo: repo)
                } catch {
                    NSLog("[Graftty] reconcileOnLaunch: discover failed for %@: %@",
                          repoPath, String(describing: error))
                    continue
                }
                guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else { continue }

                let result = WorktreeReconciler.reconcile(
                    existing: binding.wrappedValue.repos[repoIdx].worktrees,
                    discovered: discovered
                )
                binding.wrappedValue.repos[repoIdx].worktrees = result.merged

                // GIT-3.13 / GIT-3.15: clear cached stats/PR AND drop
                // the worktree's path/head/content watchers on every
                // stale transition — not just the FSEvents-deletion
                // path. Without this, a reconcile-driven stale keeps
                // zombie fds that block a same-path resurrection from
                // re-arming.
                for wt in result.newlyStale {
                    statsStore.clear(worktreePath: wt.path)
                    prStatusStore.clear(worktreePath: wt.path)
                    services.worktreeMonitor.stopWatchingWorktree(wt.path)
                }

                // Kick initial stats refresh for running worktrees after
                // reconciliation. Closed worktrees can be numerous sidebar
                // history; polling them makes CPU scale with inactive rows.
                for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state == .running {
                    statsStore.refresh(worktreePath: wt.path, repoPath: repoPath, branch: wt.branch)
                }
            }
            if let launcher = terminalManager.zmxLauncher {
                let liveSessions = try? await OffMainIO.run { try launcher.listSessions() }
                let recoveredPaths = Self.recoverRetainedWorktrees(appState: binding,
                    terminalManager: terminalManager, liveSessions: liveSessions)
                for path in recoveredPaths {
                    guard let (repoIndex, worktreeIndex) = binding.wrappedValue.indices(forWorktreePath: path) else { continue }
                    let repo = binding.wrappedValue.repos[repoIndex]
                    statsStore.refresh(worktreePath: path, repoPath: repo.path, branch: repo.worktrees[worktreeIndex].branch)
                }
            }
        }
    }

    @MainActor
    @discardableResult
    internal static func recoverRetainedWorktrees(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        liveSessions: Set<String>?
    ) -> [String] {
        guard let liveSessions else { return [] }
        var recoveredPaths: [String] = []
        for repoIndex in appState.wrappedValue.repos.indices {
            for worktreeIndex in appState.wrappedValue.repos[repoIndex].worktrees.indices {
                let worktree = appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex]
                let leaves = worktree.splitTree.allLeaves
                guard worktree.state == .closed,
                      !leaves.isEmpty,
                      leaves.allSatisfy({ pane in
                          worktree.paneSessions[pane].map {
                              liveSessions.contains(ZmxLauncher.sessionName(for: $0))
                          } == true
                      }) else { continue }
                appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex].state = .running
                appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex].focusedPaneSlotID = worktree.firstPane
                Self.prepareRunningWorktreeForRestore(
                    &appState.wrappedValue.repos[repoIndex].worktrees[worktreeIndex],
                    terminalManager: terminalManager
                )
                recoveredPaths.append(worktree.path)
                guard appState.wrappedValue.selectedWorktreePath == worktree.path else { continue }
                terminalManager.createSurfaces(for: worktree.splitTree,
                    paneSessions: worktree.paneSessions, worktreePath: worktree.path,
                    confirmedLiveSessions: liveSessions)
                if let pane = worktree.firstPane { terminalManager.setFocus(pane) }
            }
        }
        return recoveredPaths
    }

    @MainActor
    internal static func prepareRunningWorktreeForRestore(
        _ worktree: inout WorktreeEntry,
        terminalManager: TerminalManager
    ) {
        if worktree.splitTree.root == nil {
            worktree.splitTree = SplitTree(root: .leaf(PaneSlotID()))
        }
        worktree.ensurePaneSessionsForRunningRestore()
        terminalManager.recordPaneSessions(
            for: worktree.splitTree,
            paneSessions: worktree.paneSessions,
            worktreePath: worktree.path
        )
        _ = worktree.normalizeFocusedPane()
        let primaryPane = worktree.ensurePrimaryPane()
        // Mark every restored leaf as rehydrated *before* surface creation
        // so surviving zmx sessions never receive another default command.
        for leafID in worktree.splitTree.allLeaves {
            terminalManager.markRehydrated(leafID)
            terminalManager.registerForPortScan(leafID)
        }
        // If zmx reports a session missing, createSurfaces clears only that
        // leaf's rehydration marker. Retaining one primary marker lets the
        // first-pane-only policy restart exactly one default command.
        if let primaryPane {
            terminalManager.markFirstPane(primaryPane)
        }
    }

    func restoreRunningWorktrees() {
        let selectedPath = appState.selectedWorktreePath
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices
            where appState.repos[repoIdx].worktrees[wtIdx].state == .running {
                Self.prepareRunningWorktreeForRestore(
                    &appState.repos[repoIdx].worktrees[wtIdx],
                    terminalManager: terminalManager
                )
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                guard wt.path == selectedPath else { continue }
                _ = terminalManager.createSurfaces(
                    for: wt.splitTree,
                    paneSessions: wt.paneSessions,
                    worktreePath: wt.path
                )
            }
        }

        // Tell libghostty which pane is active for the currently-selected
        // worktree, so the cursor blinks in the right place on launch.
        // AppKit first-responder follows via `SurfaceNSView.viewDidMoveToWindow`
        // once SwiftUI attaches the view.
        if let path = appState.selectedWorktreePath,
           let wt = appState.worktree(forPath: path),
           wt.state == .running,
           let target = wt.firstPane {
            terminalManager.setFocus(target)
        }

        // STATE-2.12: resume auto-clear timers for any persisted attention
        // that carried a `clearAfter`. The timer is in-memory only when
        // first set (ControlRequestCore / setAttentionForTerminal schedule
        // an in-process timer), so a force-quit mid-window
        // leaves the attention stuck in state.json with no live timer.
        // Without this resume step, the badge persists until the user
        // clicks the worktree (STATE-2.4).
        resumePersistedAttentionTimers()
    }

    @MainActor
    private func resumePersistedAttentionTimers() {
        let now = Date()
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                let path = wt.path

                if let attention = wt.attention,
                   let remaining = AttentionResumePolicy.remainingTime(for: attention, now: now) {
                    let stamp = attention.timestamp
                    let appStateBinding = $appState
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        for ri in appStateBinding.wrappedValue.repos.indices {
                            for wi in appStateBinding.wrappedValue.repos[ri].worktrees.indices {
                                if appStateBinding.wrappedValue.repos[ri].worktrees[wi].path == path {
                                    appStateBinding.wrappedValue.repos[ri].worktrees[wi]
                                        .clearAttentionIfTimestamp(stamp)
                                }
                            }
                        }
                    }
                }

                for (terminalID, attention) in wt.paneAttention {
                    guard let remaining = AttentionResumePolicy.remainingTime(for: attention, now: now) else {
                        continue
                    }
                    let stamp = attention.timestamp
                    let appStateBinding = $appState
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        for ri in appStateBinding.wrappedValue.repos.indices {
                            for wi in appStateBinding.wrappedValue.repos[ri].worktrees.indices {
                                if appStateBinding.wrappedValue.repos[ri].worktrees[wi].path == path {
                                    appStateBinding.wrappedValue.repos[ri].worktrees[wi]
                                        .clearPaneAttentionIfTimestamp(stamp, for: terminalID)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
