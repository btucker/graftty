import SwiftUI
import AppKit
import GrafttyKit

struct MainWindow: View {
    @Binding var appState: AppState
    @ObservedObject var terminalManager: TerminalManager
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let worktreeMonitor: WorktreeMonitor

    /// Debounces writes of `sidebarWidth` to AppState so a drag doesn't
    /// generate hundreds of save-to-disk events.
    @State private var pendingSidebarWidthTask: Task<Void, Never>?

    /// Column visibility state — must be a real `@State` rather than a
    /// `.constant(...)` so the toolbar toggle button actually toggles.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility
        ) {
            SidebarView(
                appState: $appState,
                terminalManager: terminalManager,
                theme: terminalManager.theme,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                onSelect: selectWorktree,
                onSelectPane: selectPane,
                onAddRepo: addRepository,
                onAddPath: addPath,
                onRemoveRepo: removeRepoWithConfirmation,
                onStopWorktree: stopWorktreeWithConfirmation,
                onDeleteWorktree: deleteWorktreeWithConfirmation,
                onMovePane: movePane,
                onAddWorktree: addWorktree
            )
            .navigationSplitViewColumnWidth(
                min: 180,
                ideal: appState.sidebarWidth,
                max: 400
            )
            // Deliberately do NOT call ignoresSafeArea here. The sidebar
            // respects the title-bar safe area so its content begins below
            // the traffic lights rather than colliding with them. The
            // detail column opts out so the breadcrumb sits alongside the
            // traffic lights.
        } detail: {
            VStack(spacing: 0) {
                BreadcrumbBar(
                    repoName: selectedRepo?.displayName,
                    worktreeDisplayName: worktreeDisplayName,
                    worktreePath: selectedWorktree?.path,
                    branchName: selectedWorktree?.displayBranch,
                    isHomeCheckout: isHomeCheckout,
                    prInfo: prInfo,
                    theme: terminalManager.theme,
                    onRefreshPR: refreshPR
                )

                if let worktree = selectedWorktreeBinding {
                    TerminalContentView(
                        terminalManager: terminalManager,
                        splitTree: Binding(
                            get: { worktree.wrappedValue.splitTree },
                            set: { worktree.wrappedValue.splitTree = $0 }
                        ),
                        onFocusTerminal: { terminalID in
                            // Persist the focus change on the model BEFORE
                            // routing to libghostty: `TERM-2.3`'s focus-
                            // restore after a worktree switch reads
                            // `focusedTerminalID`, so a mouse-click that
                            // only called `setFocus` (the libghostty side)
                            // used to let focus snap back to the first leaf
                            // on the next return visit.
                            if let wtPath = appState.selectedWorktreePath {
                                appState.setFocusedTerminal(terminalID, forWorktreePath: wtPath)
                            }
                            terminalManager.setFocus(terminalID)
                        }
                    )
                    // A hair of breathing room so terminal text doesn't
                    // slam into the sidebar divider.
                    .padding(.leading, 6)
                } else {
                    ContentUnavailableView(
                        "No Worktree Selected",
                        systemImage: "terminal",
                        description: Text("Select a worktree from the sidebar or add a repository.")
                    )
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        // Tint the NSWindow to match the terminal theme: background color,
        // transparent titlebar + full-size content view, and NSAppearance
        // matching the theme's dark/light-ness so system chrome (traffic
        // lights, context menus, alerts) renders with correct contrast.
        .windowBackgroundTint(theme: terminalManager.theme)
        // Force the SwiftUI color scheme from the theme so SwiftUI-rendered
        // chrome — the NavigationSplitView sidebar toggle in particular —
        // picks the right icon shade. NSWindow.appearance covers AppKit
        // controls (traffic lights, alerts, context menus), but SwiftUI
        // toolbar items resolve through ColorScheme, not NSAppearance.
        .preferredColorScheme(terminalManager.theme.isDark ? .dark : .light)
        .trackWindowFrame(
            initialFrame: initialWindowRect
        ) { [$appState] frame in
            let newFrame = WindowFrame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )
            if $appState.wrappedValue.windowFrame != newFrame {
                $appState.wrappedValue.windowFrame = newFrame
            }
        }
        .onAppear {
            // Wired here rather than in GrafttyApp.startup() so the
            // closure captures MainWindow's `$appState` binding — both
            // NSAlert presentation and the "offered" write-back need it.
            prStatusStore.onPRMerged = { worktreePath, prNumber in
                offerDeleteForMergedPR(worktreePath: worktreePath, prNumber: prNumber)
            }
        }
        .onPreferenceChange(SidebarWidthKey.self) { [$appState, $pendingSidebarWidthTask] width in
            // Debounce by 250ms so a drag doesn't write on every layout
            // pass. Only writes if the value actually changed (value-equality
            // check prevents feedback loops with the onChange save handler).
            $pendingSidebarWidthTask.wrappedValue?.cancel()
            $pendingSidebarWidthTask.wrappedValue = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                if $appState.wrappedValue.sidebarWidth != width {
                    $appState.wrappedValue.sidebarWidth = width
                }
            }
        }
    }

    /// The initial window rect to apply on first attach.
    ///
    /// Always returns a non-nil value: SwiftUI's `.defaultSize(width:height:)`
    /// on the scene is ignored when NavigationSplitView's detail content has
    /// an intrinsic size (e.g. `ContentUnavailableView`), so the window comes
    /// up at the content's minimum — roughly 472×312 on macOS 14 — which is
    /// way too small to be usable. Forcing the frame via `NSWindow.setFrame`
    /// in `WindowFrameTracker` is the only reliable way.
    ///
    /// Priority:
    /// 1. Saved non-default frame, if it overlaps a connected screen → apply as-is.
    /// 2. Otherwise → center the default size (from `WindowFrame()`) on the
    ///    primary screen's visible frame. This covers both first launch and
    ///    the "user unplugged the external monitor the window was parked on"
    ///    case.
    private var initialWindowRect: CGRect? {
        let savedFrame = appState.windowFrame
        let defaultFrame = WindowFrame()
        if savedFrame != defaultFrame {
            let rect = CGRect(x: savedFrame.x, y: savedFrame.y,
                              width: savedFrame.width, height: savedFrame.height)
            if WindowFrameTracker.Coordinator.frameIsVisibleOnAnyScreen(rect) {
                return rect
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screen.minX + (screen.width - defaultFrame.width) / 2
        let originY = screen.minY + (screen.height - defaultFrame.height) / 2
        return CGRect(x: originX, y: originY,
                      width: defaultFrame.width, height: defaultFrame.height)
    }

    private var selectedRepo: RepoEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.repo(forWorktreePath: path)
    }

    private var selectedWorktree: WorktreeEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.worktree(forPath: path)
    }

    private var selectedWorktreeBinding: Binding<WorktreeEntry>? {
        guard let path = appState.selectedWorktreePath else { return nil }
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    return $appState.repos[repoIdx].worktrees[wtIdx]
                }
            }
        }
        return nil
    }

    private var isHomeCheckout: Bool {
        guard let repo = selectedRepo, let wt = selectedWorktree else { return false }
        return wt.path == repo.path
    }

    private var worktreeDisplayName: String? {
        guard let repo = selectedRepo, let wt = selectedWorktree else { return nil }
        return wt.displayName(amongSiblingPaths: repo.worktrees.map(\.path))
    }

    private var prInfo: PRInfo? {
        guard let path = selectedWorktree?.path else { return nil }
        return prStatusStore.infos[path]
    }

    private func refreshPR() {
        guard let wt = selectedWorktree, let repo = selectedRepo else { return }
        prStatusStore.refresh(worktreePath: wt.path, repoPath: repo.path, branch: wt.branch)
    }

    /// Selects a worktree *and* focuses a specific pane within it. Used by
    /// the sidebar's per-pane title rows so clicking "claude" under a
    /// worktree both activates that worktree and focuses Claude's pane.
    private func selectPane(_ worktreePath: String, _ terminalID: TerminalID) {
        selectWorktree(worktreePath)
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                    appState.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = terminalID
                }
            }
        }
        terminalManager.setFocus(terminalID)
        makePaneFirstResponder(terminalID)
    }

    private func selectWorktree(_ path: String) {
        appState.selectedWorktreePath = path

        // Resurrect stale entries whose directory is actually still on
        // disk. Same rule as the background reconciler's `GIT-3.7`, but
        // applied eagerly on user click so the content area doesn't
        // sit on the `Color.black + ProgressView` fallback when the
        // user expected terminals. Cleared split tree too — a stale
        // entry's old leaf IDs reference surfaces that were destroyed,
        // so starting fresh is safer than trying to restore them.
        var resurrectedRepoPath: String?
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == path && wt.state == .stale &&
                   FileManager.default.fileExists(atPath: path) {
                    let orphan = appState.repos[repoIdx].worktrees[wtIdx]
                        .prepareForResurrection()
                    if !orphan.isEmpty {
                        terminalManager.destroySurfaces(terminalIDs: orphan)
                    }
                    resurrectedRepoPath = appState.repos[repoIdx].path
                }
            }
        }
        // `GIT-3.15`: `stopWatchingWorktree` ran on the stale
        // transition, so the resurrected worktree has no path / head /
        // content watchers. Re-arm now so real-time stats and PR
        // refreshes work without waiting for the next `.git/worktrees/`
        // FSEvents tick (which a user-click resurrection never fires).
        if let repoPath = resurrectedRepoPath {
            worktreeMonitor.watchWorktreePath(path)
            worktreeMonitor.watchHeadRef(worktreePath: path, repoPath: repoPath)
            worktreeMonitor.watchWorktreeContents(worktreePath: path)
        }

        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path
                    && appState.repos[repoIdx].worktrees[wtIdx].state == .closed {

                    if appState.repos[repoIdx].worktrees[wtIdx].splitTree.root == nil {
                        let id = TerminalID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }

                    let splitTree = appState.repos[repoIdx].worktrees[wtIdx].splitTree
                    // Mark every leaf as a first-pane candidate *before*
                    // createSurfaces — the first PWD event could arrive
                    // immediately after the surface spawns, and
                    // maybeRunDefaultCommand queries isFirstPane at that
                    // time. In the common case there's exactly one leaf
                    // (fresh open); marking all of them keeps this robust
                    // against future layouts that seed multiple leaves.
                    for leafID in splitTree.allLeaves {
                        terminalManager.markFirstPane(leafID)
                    }
                    _ = terminalManager.createSurfaces(for: splitTree, worktreePath: path)

                    appState.repos[repoIdx].worktrees[wtIdx].state = .running
                }
            }
        }

        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    // Clicking a worktree dismisses both levels of
                    // attention — worktree-level (CLI notify) and any
                    // outstanding per-pane badges from shell integration
                    // — so the user sees a clean slate once they're
                    // looking at the worktree.
                    appState.repos[repoIdx].worktrees[wtIdx].attention = nil
                    appState.repos[repoIdx].worktrees[wtIdx].paneAttention.removeAll()
                }
            }
        }

        // Route keyboard to the worktree's currently-focused pane (or the
        // first leaf if nothing was focused yet) so the user can start
        // typing immediately after a sidebar click without having to also
        // click into the terminal.
        if let wt = appState.worktree(forPath: path),
           let target = wt.focusedTerminalID ?? wt.splitTree.allLeaves.first {
            makePaneFirstResponder(target)
        }

        // PR-7.5: sidebar selection is an on-demand refresh trigger.
        // `prStatusStore.refresh` bypasses the cadence gate so a
        // user-visible click always gets fresh data even when the poll
        // is backed off (`PR-7.2` can push the next scheduled fetch out
        // to 30 minutes after a run of transient `gh` failures). Without
        // this, a merged PR can stay red in the breadcrumb until the
        // backoff expires, and the user's only escape hatch is
        // right-click "Refresh now" on the PR button.
        refreshPR()
    }

    /// Promote the terminal's backing `NSView` to the window's first
    /// responder so keyDown events route to libghostty. Dispatched async
    /// because the view may have just been created by `createSurfaces` and
    /// SwiftUI hasn't attached it to the window hierarchy yet — you can't
    /// `makeFirstResponder` a view that isn't in a window.
    private func makePaneFirstResponder(_ terminalID: TerminalID) {
        let tm = terminalManager
        DispatchQueue.main.async {
            guard let view = tm.view(for: terminalID),
                  let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    /// Delegates to `AddWorktreeFlow.add` for the git + discover + spawn
    /// pipeline (shared with the web client's `POST /worktrees`), then
    /// flips `selectedWorktreePath` and routes keyboard focus — the
    /// parts of "select" that only apply to the local Mac window. The
    /// web entry point deliberately skips those so remote-creating a
    /// worktree doesn't yank local focus away.
    private func addWorktree(
        repo: RepoEntry,
        worktreeName: String,
        branchName: String
    ) async -> String? {
        let result = await AddWorktreeFlow.add(
            repoPath: repo.path,
            worktreeName: worktreeName,
            branchName: branchName,
            appState: $appState,
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            terminalManager: terminalManager
        )
        switch result {
        case .failure(let err):
            switch err {
            case .gitFailed(let msg): return msg
            case .repoNotFound: return "repository no longer tracked"
            case .discoveryFailed(let msg):
                // The worktree creation itself succeeded; we just can't
                // confirm it. Log and mirror the GIT-3.12 pattern of
                // letting FSEvents eventually catch up.
                NSLog("[Graftty] addWorktree: post-success discover failed for %@: %@",
                      repo.path, msg)
                return nil
            }
        case .success(let outcome):
            // `selectWorktree` is idempotent on the `.closed → .running`
            // transition `AddWorktreeFlow.add` already performed; its
            // remaining work is the UI-local side effects (first
            // responder, PR refresh, `selectedWorktreePath`).
            selectWorktree(outcome.worktreePath)
            return nil
        }
    }

    private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository or worktree directory"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addPath(url.path)
    }

    func addPath(_ path: String) {
        let detection: GitPathType
        do {
            detection = try GitRepoDetector.detect(path: path)
        } catch {
            // `detect` throws when `.git` exists but can't be read
            // (permissions glitch, truncated file, FS error). Surface
            // it to the user — otherwise a dragged folder silently
            // fails to appear. Same policy as `GIT-1.3` on `discover`.
            NSLog("[Graftty] addPath: detect failed for %@: %@",
                  path, String(describing: error))
            let alert = NSAlert()
            alert.messageText = "Could not add repository"
            alert.informativeText = "\(path)\n\n\(String(describing: error))"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        switch detection {
        case .repoRoot(let repoPath):
            addRepoFromPath(repoPath, selectWorktree: nil)
        case .worktree(let worktreePath, let repoPath):
            addRepoFromPath(repoPath, selectWorktree: worktreePath)
        case .notARepo:
            let alert = NSAlert()
            alert.messageText = "Not a Git Repository"
            alert.informativeText = "\(path) is not a git repository or worktree."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Prompts for confirmation, tears down any running terminals, and
    /// shells to `git worktree remove`. The branch the worktree had
    /// checked out is left intact — that's the contract the confirmation
    /// dialog promises the user. On success, the entry is removed from
    /// `appState` synchronously; the FSEvents watcher will also fire
    /// `worktreeMonitorDidDetectDeletion` shortly after, but its update
    /// is idempotent so the eventual callback is harmless.
    private func deleteWorktreeWithConfirmation(_ worktreePath: String) {
        let alert = NSAlert()
        alert.messageText = "Delete Worktree?"
        alert.informativeText = "This will delete the worktree but not the branch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Worktree")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performDeleteWorktree(worktreePath)
    }

    private func removeRepoWithConfirmation(_ repo: RepoEntry) {
        let alert = NSAlert()
        alert.messageText = "Remove \"\(repo.displayName)\"?"
        alert.informativeText = "This removes the repository from Graftty but does not delete any files from disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performRemoveRepo(repo)
    }

    /// Implements LAYOUT-4.3. Ordering of (a)–(d) before (e) matches the
    /// orphan-surfaces / orphan-caches contracts in GIT-3.10 / GIT-4.10 /
    /// GIT-3.13 / GIT-3.11. No git is invoked; no on-disk files are
    /// touched.
    private func performRemoveRepo(_ repo: RepoEntry) {
        // (a) Tear down live surfaces for running worktrees. Covers
        // stale-while-running surfaces kept alive by GIT-3.4.
        for wt in repo.worktrees where wt.state == .running {
            terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)
        }
        // (b) + (c) Stop repo-level and per-worktree watchers and clear
        // per-path caches. Shared with the relocate cascade — see
        // `RepoTeardown` for the rationale on the per-worktree loop.
        RepoTeardown.stopWatchersAndClearCaches(
            repo: repo,
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            prStatusStore: prStatusStore
        )
        // (d) + (e) `AppState.removeRepo` clears selection when victim.
        appState.removeRepo(atPath: repo.path)
    }

    /// Shared `git worktree remove` + teardown path used by both the
    /// user-initiated "Delete Worktree" menu action and the PR-merged
    /// offer dialog. Callers own the confirmation UX — this helper runs
    /// git unconditionally and surfaces failures via the same error
    /// alert as the menu path.
    private func performDeleteWorktree(_ worktreePath: String) {
        guard let (repoIdx, wtIdx) = appState.indices(forWorktreePath: worktreePath) else { return }
        let wt = appState.repos[repoIdx].worktrees[wtIdx]
        let repoPath = appState.repos[repoIdx].path

        // Run git first so a refusal (e.g. dirty worktree) leaves the
        // running terminals intact — tearing them down before we know
        // whether the delete will succeed would leave the user with a
        // visible worktree and dead panes.
        Task { @MainActor in
            do {
                try await GitWorktreeRemove.remove(repoPath: repoPath, worktreePath: worktreePath)
            } catch GitWorktreeRemove.Error.gitFailed(_, let stderr) {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could not delete worktree"
                errorAlert.informativeText = stderr.isEmpty ? "git worktree remove failed" : stderr
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
                return
            } catch {
                // Non-git-exit errors (git binary missing, subprocess launch
                // failure, etc.). User clicked Delete Worktree; a silent
                // bail leaves them wondering why nothing happened. Match
                // the Add Repository path (GIT-1.2) with an alert. GIT-4.11.
                NSLog("[Graftty] performDeleteWorktree: git launch failed for %@: %@",
                      worktreePath, String(describing: error))
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could not delete worktree"
                errorAlert.informativeText = "\(error)"
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
                return
            }

            if wt.state == .running {
                terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)
            }
            // GIT-4.10: drop per-path caches BEFORE removing the model
            // entry. Same reason `dismissWorktree` (GIT-3.6) does: orphan
            // cache entries survive indefinitely and bleed into a future
            // same-path re-add (rare but cheap — path-keyed caches aren't
            // inode-scoped). Runs unconditionally; clear on a never-cached
            // path is a no-op.
            prStatusStore.clear(worktreePath: worktreePath)
            statsStore.clear(worktreePath: worktreePath)
            appState.removeWorktree(atPath: worktreePath)
        }
    }

    /// Called by `PRStatusStore.onPRMerged` on the first observed
    /// transition of a worktree's PR cache into `.merged`. Presents the
    /// offer dialog iff this is a linked (non-main, non-stale) worktree
    /// and we haven't already offered for this PR number. The "offered"
    /// marker is persisted via `AppState.onChange` so Keep is sticky
    /// across restarts, not just across polls.
    private func offerDeleteForMergedPR(worktreePath: String, prNumber: Int) {
        guard let (repoIdx, wtIdx) = appState.indices(forWorktreePath: worktreePath) else { return }
        let repo = appState.repos[repoIdx]
        let wt = repo.worktrees[wtIdx]

        // Mirrors GIT-4.1: git refuses to remove the main checkout, and
        // a stale entry has no live worktree to remove.
        guard wt.path != repo.path, wt.state != .stale else { return }
        guard wt.offeredDeleteForMergedPR != prNumber else { return }

        // Mark as offered *before* presenting the modal so a user who
        // clicks Keep doesn't get re-prompted on the next poll.
        appState.repos[repoIdx].worktrees[wtIdx].offeredDeleteForMergedPR = prNumber

        let alert = NSAlert()
        alert.messageText = "Pull request #\(prNumber) merged"
        alert.informativeText = "Delete the worktree now? This will delete the worktree but not the branch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Delete Worktree")
        alert.addButton(withTitle: "Keep")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performDeleteWorktree(worktreePath)
    }

    private func movePane(_ terminalID: TerminalID, to newPWD: String) {
        GrafttyApp.reassignPaneByPWD(
            appState: $appState,
            terminalManager: terminalManager,
            terminalID: terminalID,
            newPWD: newPWD
        )
    }

    private func stopWorktreeWithConfirmation(_ worktreePath: String) {
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                let wt = appState.repos[repoIdx].worktrees[wtIdx]
                if wt.path == worktreePath && wt.state == .running {
                    let terminalIDs = wt.splitTree.allLeaves
                    if terminalManager.needsConfirmQuit(terminalIDs: terminalIDs) {
                        // TERM-1.3: the dialog identifies the worktree
                        // with its sidebar displayName, not the raw
                        // `wt.branch`. For a detached HEAD that's
                        // `(detached)` — awkward ("running processes in
                        // (detached)") — whereas displayName gives the
                        // directory basename users actually recognise.
                        let siblingPaths = appState.repos[repoIdx].worktrees.map(\.path)
                        let label = wt.displayName(amongSiblingPaths: siblingPaths)
                        let alert = NSAlert()
                        alert.messageText = "Stop Worktree?"
                        alert.informativeText = "There are running processes in \(label). Stop all terminals?"
                        alert.addButton(withTitle: "Stop")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    terminalManager.destroySurfaces(terminalIDs: terminalIDs)
                    // STATE-2.11: Stop clears pane-scoped attention. Stop
                    // preserves splitTree so re-open recreates the same
                    // layout at the same leaf IDs (TERM-1.2) — which
                    // means stale `paneAttention[ID]` from before the
                    // Stop would reappear on the fresh pane's row
                    // without this clear.
                    appState.repos[repoIdx].worktrees[wtIdx].prepareForStop()
                    return
                }
            }
        }
    }

    private func addRepoFromPath(_ repoPath: String, selectWorktree: String?) {
        guard !appState.repos.contains(where: { $0.path == repoPath }) else {
            if let wt = selectWorktree {
                appState.selectedWorktreePath = wt
            }
            return
        }

        Task { @MainActor in
            let discovered: [DiscoveredWorktree]
            do {
                discovered = try await GitWorktreeDiscovery.discover(repoPath: repoPath)
            } catch {
                // User-initiated path: the user picked a folder in the
                // Add Repository dialog. If git discovery fails (folder
                // isn't a repo, git binary missing, permissions), a
                // silent `return` leaves the user wondering why nothing
                // happened. Surface the failure in an alert so they can
                // pick a different folder or investigate. GIT-1.2.
                NSLog("[Graftty] addRepoFromPath: discover failed for %@: %@",
                      repoPath, String(describing: error))
                let alert = NSAlert()
                alert.messageText = "Could not add repository"
                alert.informativeText = "\(repoPath)\n\n\(String(describing: error))"
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            let worktrees = discovered.map { WorktreeEntry(path: $0.path, branch: $0.branch) }
            let displayName = URL(fileURLWithPath: repoPath).lastPathComponent
            let bookmark = try? RepoBookmark.mint(atPath: repoPath)
            if bookmark == nil {
                NSLog("[Graftty] addRepoFromPath: bookmark mint failed for %@; rename-recovery disabled for this entry", repoPath)
            }
            let repo = RepoEntry(
                path: repoPath,
                displayName: displayName,
                worktrees: worktrees,
                bookmark: bookmark
            )
            appState.addRepo(repo)

            if let wt = selectWorktree {
                self.selectWorktree(wt)
            } else if let first = worktrees.first {
                self.selectWorktree(first.path)
            }
        }
    }
}
