import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

enum MainWindowSelection: Equatable {
    case flowState
    case worktree(String?)
}

struct MainWindowSelectionTransition: Equatable {
    let selection: MainWindowSelection
    let selectedWorktreePath: String?

    static func selectFlowState(currentWorktreePath: String?) -> MainWindowSelectionTransition {
        MainWindowSelectionTransition(selection: .flowState, selectedWorktreePath: currentWorktreePath)
    }

    static func selectWorktree(_ path: String) -> MainWindowSelectionTransition {
        MainWindowSelectionTransition(selection: .worktree(path), selectedWorktreePath: path)
    }

    static func resolveWorktreePath(target: String, repos: [RepoEntry]) -> String? {
        var matches: [String] = []
        for repo in repos {
            for worktree in repo.worktrees {
                let key = FlowWorktreeIdentity.key(repoPath: repo.path, worktreePath: worktree.path)
                let ref = FlowWorktreeIdentity.ref(
                    repoDisplayName: repo.displayName,
                    repoPath: repo.path,
                    worktreePath: worktree.path,
                    branch: worktree.branch
                )
                let memberName = WorktreeNameSanitizer.sanitize(worktree.branch)
                let displayRef = "\(repo.displayName):\(memberName)"
                if [ref, key, displayRef, memberName, worktree.path].contains(target) {
                    matches.append(worktree.path)
                }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum MainWindowPaneCommandTarget {
    static func resolve(
        selection: MainWindowSelection,
        selectedWorktreeFocusedPane: PaneSlotID?,
        flowStateFocusedPane: PaneSlotID?
    ) -> PaneSlotID? {
        switch selection {
        case .flowState:
            return nil
        case .worktree:
            return selectedWorktreeFocusedPane
        }
    }
}

enum FlowStateViewOpenRefreshPolicy {
    static func shouldRequestRefresh(
        wasRunningBeforeOpen: Bool,
        isRunningAfterOpen: Bool
    ) -> Bool {
        isRunningAfterOpen
    }
}

private struct FlowStateViewTeamMessenger: FlowTeamMessaging {
    func sendStatusRequest(target: String, body: String) throws {
        throw FlowTeamMessagingError.skipped("Flow State status request from the view is unavailable until the agent lifecycle is wired.")
    }

    func sendMessage(target: String, body: String) throws {
        throw FlowTeamMessagingError.skipped("Flow State team message from the view is unavailable until the agent lifecycle is wired.")
    }
}

private struct FlowStateViewAppActions: FlowConfirmedAppActions {
    let repos: [RepoEntry]
    let selectWorktree: (String) -> Void

    func focusWorktree(ref: String) throws {
        guard let path = MainWindowSelectionTransition.resolveWorktreePath(target: ref, repos: repos) else {
            throw FlowTeamMessagingError.skipped("Flow State focus action skipped: unresolved worktree \(ref)")
        }
        selectWorktree(path)
    }

    func restartAgent(ref: String) throws {
        throw FlowTeamMessagingError.skipped("Flow State restart is unavailable until the agent lifecycle is wired.")
    }
}

struct MainWindow: View {
    @Binding var appState: AppState
    @ObservedObject var terminalManager: TerminalManager
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let claudeSessionRegistry: ClaudeSessionRegistry
    let remoteBranchStore: RemoteBranchStore
    let worktreeMonitor: WorktreeMonitor
    let teamEventDispatcher: TeamEventDispatcher
    @ObservedObject var flowStateAgentController: FlowStateAgentController
    var onMainSelectionChange: (MainWindowSelection) -> Void = { _ in }

    @EnvironmentObject private var updaterController: UpdaterController

    /// Column visibility state — must be a real `@State` rather than a
    /// `.constant(...)` so the toolbar toggle button actually toggles.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Lifted from SidebarView so the ⌘T command handler (scoped to the
    /// SwiftUI scene commands block, which can't reach view-local state)
    /// can present the Add Worktree sheet pre-scoped to the current repo.
    @State private var pendingAddWorktree: AddWorktreeRequest?

    @State private var mainSelection: MainWindowSelection = .worktree(nil)
    @State private var flowStateRecommendation: FlowRecommendationEnvelope?
    @State private var flowStateActivity: [FlowStateActivity] = []

    private let flowStateStore = FlowStateStore.defaultStore()
    private let flowStateActivityStore = FlowStateActivityStore.defaultStore()

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility
        ) {
            SidebarView(
                appState: $appState,
                terminalManager: terminalManager,
                paneTitleInvalidations: terminalManager.paneTitleInvalidations,
                theme: terminalManager.theme,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                claudeSessionRegistry: claudeSessionRegistry,
                remoteBranchStore: remoteBranchStore,
                flowStateStatus: flowStateAgentController.status,
                flowStateRecommendation: flowStateRecommendation,
                isFlowStateSelected: mainSelection == .flowState,
                onSelectFlowState: selectFlowState,
                onSelect: selectWorktree,
                onSelectPane: selectPane,
                onAddRepo: addRepository,
                onAddPath: addPath,
                onRemoveRepo: removeRepoWithConfirmation,
                onInitializeGit: initializeGitRepositoryInPlace,
                onStopWorktree: stopWorktreeWithConfirmation,
                onDeleteWorktree: deleteWorktreeWithConfirmation,
                onMovePane: movePane,
                onAddWorktree: addWorktree,
                pendingAddWorktree: $pendingAddWorktree
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
                if mainSelection == .flowState {
                    FlowStateView(
                        terminalManager: terminalManager,
                        agentController: flowStateAgentController,
                        status: flowStateAgentController.status,
                        recommendation: flowStateRecommendation,
                        activity: flowStateActivity,
                        requestRefresh: { refreshFlowState(reason: "manual refresh") },
                        openAgentPane: openFlowStateAgentPane,
                        restartAgent: { try? flowStateAgentController.restart() },
                        confirmAction: confirmFlowStateAction
                    )
                    .onAppear(perform: flowStateViewDidAppear)
                } else {
                    BreadcrumbBar(
                        repoName: selectedRepo?.displayName,
                        worktreeDisplayName: worktreeDisplayName,
                        worktreePath: selectedWorktree?.path,
                        branchName: selectedWorktree?.displayBranch,
                        isHomeCheckout: isHomeCheckout,
                        prInfo: prInfo,
                        theme: terminalManager.theme,
                        sidebarHidden: columnVisibility == .detailOnly,
                        onRefreshPR: refreshPR
                    )

                    if let worktree = selectedWorktreeBinding {
                        TerminalContentView(
                            terminalManager: terminalManager,
                            splitTree: Binding(
                                get: { worktree.wrappedValue.splitTree },
                                set: { worktree.wrappedValue.splitTree = $0 }
                            ),
                            focusedPaneSlotID: worktree.wrappedValue.focusedPaneSlotID,
                            theme: terminalManager.theme,
                            onFocusTerminal: { terminalID in
                                // Persist the focus change on the model BEFORE
                                // routing to libghostty: `TERM-2.3`'s focus-
                                // restore after a worktree switch reads
                                // `focusedPaneSlotID`, so a mouse-click that
                                // only called `setFocus` (the libghostty side)
                                // used to let focus snap back to the first leaf
                                // on the next return visit.
                                if let wtPath = appState.selectedWorktreePath {
                                    appState.setFocusedTerminal(terminalID, forWorktreePath: wtPath)
                                    // STATE-2.4: clicking a pane's terminal to
                                    // focus it acknowledges that pane's attention
                                    // (e.g. the agent-stop "needs input" icon),
                                    // same as clicking its sidebar row.
                                    appState.acknowledgePaneAttention(terminalID, forWorktreePath: wtPath)
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
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        // Tint the NSWindow to match the terminal theme: background color,
        // transparent titlebar + full-size content view, and NSAppearance
        // matching the theme's dark/light-ness so system chrome (traffic
        // lights, context menus, alerts) renders with correct contrast.
        .windowBackgroundTint(theme: terminalManager.theme)
        .installUpdateBadgeAccessory(controller: updaterController)
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
            prStatusStore.onPRResolved = { worktreePath, prNumber, prTitle, state in
                offerDeleteForResolvedPR(worktreePath: worktreePath, prNumber: prNumber, prTitle: prTitle, state: state)
            }
        }
        .focusedSceneValue(\.addWorktreeAction, addWorktreeAction)
        .focusedSceneValue(\.worktreeNavAction, worktreeNavAction)
        .persistSidebarWidth(to: Binding(
            get: { appState.sidebarWidth },
            set: { appState.sidebarWidth = $0 }
        ))
        .onChange(of: appState.selectedWorktreePath, initial: true) { oldPath, newPath in
            if oldPath != newPath || mainSelection == .worktree(nil) {
                mainSelection = .worktree(newPath)
            }
            guard let newPath else { return }
            terminalManager.surfaceBudget.noteSelected(
                worktreePath: newPath,
                splitTreesByPath: appState.runningSplitTreesByPath()
            )
        }
        .onChange(of: mainSelection, initial: true) { _, newSelection in
            onMainSelectionChange(newSelection)
        }
        // AGENT-3.4 resume rule runs at the model layer via
        // ClaudeSessionRegistry.onLivenessChange (wired in startup), so it
        // applies to the iPad/web snapshot and the window-closed case too —
        // not just while this view is on screen.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            applyAppVisibility(isVisible: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            applyAppVisibility(isVisible: true)
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

    /// Computed command handler surfaced to `GrafttyApp.commands` via
    /// `@FocusedValue`. `nil` means no worktree is selected → menu item
    /// disabled. Captures `appState` and `terminalManager` so the scene-
    /// level commands block doesn't need direct access to either.
    private var addWorktreeAction: (() -> Void)? {
        guard let repo = selectedRepo else { return nil }
        return {
            var prefill = ""
            if let termID = selectedWorktree?.focusedPaneSlotID,
               let selection = terminalManager.readSelection(for: termID) {
                prefill = WorktreeNameSanitizer.sanitizeForPrefill(selection)
            }
            // Kick off fresh branch + PR data so the BranchPicker
            // renders something current as the sheet appears, even if
            // the polling cadence is in a long-backoff.
            remoteBranchStore.pulse()
            prStatusStore.pulse()
            pendingAddWorktree = AddWorktreeRequest(repo: repo, prefill: prefill)
        }
    }

    /// Command handler surfaced to `GrafttyApp.commands` via `@FocusedValue`
    /// for `next_tab` / `previous_tab` (KBD-5). `nil` when there is nothing
    /// to move to, so the menu items disable. Routes through the same
    /// `selectWorktree` sidebar clicks use, so surface show/hide and
    /// `acknowledgeAttention()` all fire identically.
    private var worktreeNavAction: ((Bool) -> Void)? {
        guard mainSelection != .flowState else { return nil }
        // Enablement is direction-agnostic: `nextWorktreePath` returns nil in
        // exactly one case — 0/1 selectable worktrees — for both directions,
        // so probing `forward: true` correctly gates Next and Previous alike.
        guard appState.nextWorktreePath(forward: true) != nil else { return nil }
        return { forward in
            if let target = appState.nextWorktreePath(forward: forward) {
                selectWorktree(target)
            }
        }
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
        let defaultBranch = remoteBranchStore.resolvedDefaultBranch(
            forRepoAt: repo.path,
            hint: repo.defaultBranchHint
        )
        return SidebarWorktreeLabel.text(
            for: wt,
            inRepoAtPath: repo.path,
            siblingPaths: repo.worktrees.map(\.path),
            defaultBranch: defaultBranch
        )
    }

    private var prInfo: PRInfo? {
        guard let path = selectedWorktree?.path else { return nil }
        return prStatusStore.infos[path]
    }

    private func refreshPR() {
        guard let wt = selectedWorktree, let repo = selectedRepo else { return }
        prStatusStore.refresh(worktreePath: wt.path, repoPath: repo.path, branch: wt.branch)
    }

    private func selectFlowState() {
        let transition = MainWindowSelectionTransition.selectFlowState(
            currentWorktreePath: appState.selectedWorktreePath
        )
        mainSelection = transition.selection
        if let path = transition.selectedWorktreePath {
            setWorktreeSurfacesVisible(false, worktreePath: path)
        }
        refreshFlowState()
    }

    private func refreshFlowState(reason: String? = nil) {
        loadFlowStateData()
        if let reason {
            flowStateAgentController.requestRefresh(reason: reason)
        }
    }

    private func loadFlowStateData() {
        do {
            flowStateRecommendation = try flowStateStore.recommendation()
            flowStateActivity = try flowStateActivityStore.recent(limit: 10)
        } catch {
            flowStateActivity = [
                FlowStateActivity(
                    createdAt: Date(),
                    kind: .publishError,
                    message: "Could not read Flow State data: \(error)",
                    worktreeRef: nil
                )
            ]
        }
    }

    private func flowStateViewDidAppear() {
        flowStateAgentController.reconcileSettingsFromUserDefaults()
        let wasRunning = flowStateAgentController.status.running
        try? flowStateAgentController.ensureRunning()
        refreshFlowState(
            reason: FlowStateViewOpenRefreshPolicy.shouldRequestRefresh(
                wasRunningBeforeOpen: wasRunning,
                isRunningAfterOpen: flowStateAgentController.status.running
            ) ? "view open" : nil
        )
    }

    private func openFlowStateAgentPane() {
        selectFlowState()
        flowStateAgentController.reconcileSettingsFromUserDefaults()
        try? flowStateAgentController.ensureRunning()
        if let focusedPaneSlotID = flowStateAgentController.focusedPaneSlotID {
            makePaneFirstResponder(focusedPaneSlotID)
        }
    }

    private func confirmFlowStateAction(_ action: FlowProposedAction) {
        let executor = FlowStateActionExecutor(
            activityStore: flowStateActivityStore,
            teamMessenger: FlowStateViewTeamMessenger(),
            appActions: FlowStateViewAppActions(repos: appState.repos, selectWorktree: selectWorktree),
            permissionMode: .conservative
        )
        do {
            try executor.executeConfirmedAction(action)
        } catch {
            try? flowStateActivityStore.append(FlowStateActivity(
                createdAt: Date(),
                kind: .actionSkipped,
                message: "Flow State action failed: \(error)",
                worktreeRef: action.target
            ))
        }
        refreshFlowState()
    }

    /// Selects a worktree *and* focuses a specific pane within it. Used by
    /// the sidebar's per-pane title rows so clicking "claude" under a
    /// worktree both activates that worktree and focuses Claude's pane.
    private func selectPane(_ worktreePath: String, _ terminalID: PaneSlotID) {
        selectWorktree(worktreePath)
        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                    appState.repos[repoIdx].worktrees[wtIdx].focusedPaneSlotID = terminalID
                }
            }
        }
        terminalManager.setFocus(terminalID)
        makePaneFirstResponder(terminalID)
    }

    private func selectWorktree(_ path: String) {
        // In-flight rows have no surfaces to focus and no PR / stats
        // to refresh — let the user keep their current worktree until
        // the owning flow finalizes (`.creating → .running`, or
        // `.deleting → removed`).
        if let wt = appState.worktree(forPath: path), wt.state.isInFlight {
            return
        }
        mainSelection = MainWindowSelectionTransition.selectWorktree(path).selection
        let previousPath = appState.selectedWorktreePath
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
                if appState.repos[repoIdx].worktrees[wtIdx].path != path {
                    continue
                }

                if appState.repos[repoIdx].worktrees[wtIdx].state == .closed {

                    if appState.repos[repoIdx].worktrees[wtIdx].splitTree.root == nil {
                        let id = PaneSlotID()
                        appState.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
                    }

                    let splitTree = appState.repos[repoIdx].worktrees[wtIdx].splitTree
                    for leafID in splitTree.allLeaves {
                        appState.repos[repoIdx].worktrees[wtIdx].ensurePaneSession(for: leafID)
                    }
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
                    _ = terminalManager.createSurfaces(
                        for: splitTree,
                        paneSessions: appState.repos[repoIdx].worktrees[wtIdx].paneSessions,
                        worktreePath: path
                    )

                    appState.repos[repoIdx].worktrees[wtIdx].state = .running
                } else if appState.repos[repoIdx].worktrees[wtIdx].state == .running {
                    let splitTree = appState.repos[repoIdx].worktrees[wtIdx].splitTree
                    let missingSurface = splitTree.allLeaves.contains { terminalManager.handle(for: $0) == nil }
                    if missingSurface {
                        for leafID in splitTree.allLeaves {
                            appState.repos[repoIdx].worktrees[wtIdx].ensurePaneSession(for: leafID)
                        }
                        _ = terminalManager.createSurfaces(
                            for: splitTree,
                            paneSessions: appState.repos[repoIdx].worktrees[wtIdx].paneSessions,
                            worktreePath: path
                        )
                    }
                }
            }
        }

        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path == path {
                    // Clicking a worktree dismisses both levels of
                    // attention — worktree-level (CLI notify) and any
                    // outstanding per-pane badges — so the user sees a
                    // clean slate once they're looking at the worktree.
                    // Same `acknowledgeAttention()` the notification-
                    // activation path uses, so the two can't drift.
                    appState.repos[repoIdx].worktrees[wtIdx].acknowledgeAttention()
                }
            }
        }

        if previousPath != path, let previousPath {
            setWorktreeSurfacesVisible(false, worktreePath: previousPath)
        }
        setWorktreeSurfacesVisible(true, worktreePath: path)

        // Route keyboard to the worktree's currently-focused pane (or the
        // first leaf if nothing was focused yet) so the user can start
        // typing immediately after a sidebar click without having to also
        // click into the terminal.
        if let wt = appState.worktree(forPath: path),
           let target = wt.focusedPaneSlotID ?? wt.splitTree.allLeaves.first {
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

    private func setWorktreeSurfacesVisible(_ visible: Bool, worktreePath: String) {
        guard let wt = appState.worktree(forPath: worktreePath), wt.state == .running else { return }
        for terminalID in wt.splitTree.allLeaves {
            terminalManager.setVisible(visible, for: terminalID)
        }
    }

    private func applyAppVisibility(isVisible: Bool) {
        guard let action = AppVisibilitySurfacePolicy.action(
            selection: mainSelection,
            selectedWorktreePath: appState.selectedWorktreePath,
            appIsVisible: isVisible
        ) else { return }
        switch action {
        case let .setSelectedWorktreeVisible(path, visible):
            setWorktreeSurfacesVisible(visible, worktreePath: path)
        }
    }

    /// Promote the terminal's backing `NSView` to the window's first
    /// responder so keyDown events route to libghostty. Dispatched async
    /// because the view may have just been created by `createSurfaces` and
    /// SwiftUI hasn't attached it to the window hierarchy yet — you can't
    /// `makeFirstResponder` a view that isn't in a window.
    private func makePaneFirstResponder(_ terminalID: PaneSlotID) {
        let tm = terminalManager
        DispatchQueue.main.async {
            guard let view = tm.view(for: terminalID),
                  let window = view.window else { return }
            tm.setVisible(true, for: terminalID)
            window.makeFirstResponder(view)
        }
    }

    /// Two-phase create: `beginCreate` (sync) inserts a placeholder so
    /// the sheet dismisses immediately, then a detached `Task` runs
    /// `finishCreate` which spawns git's hooks in the background and
    /// promotes the placeholder to `.running` (or removes it + alerts
    /// on failure — the sheet is gone, so an inline error isn't an
    /// option). `discoveryFailed` from finishCreate is logged not
    /// alerted because the worktree IS on disk by that point.
    private func addWorktree(
        repo: RepoEntry,
        worktreeName: String,
        branch: BranchSelection
    ) async -> String? {
        let beginResult = AddWorktreeFlow.beginCreate(
            repoPath: repo.path,
            worktreeName: worktreeName,
            branch: branch,
            appState: $appState
        )
        let worktreePath: String
        switch beginResult {
        case .failure(let err): return err.userMessage
        case .success(let path): worktreePath = path
        }

        let dispatcher = teamEventDispatcher
        Task { @MainActor in
            let result = await AddWorktreeFlow.finishCreate(
                repoPath: repo.path,
                worktreePath: worktreePath,
                branch: branch,
                appState: $appState,
                worktreeMonitor: worktreeMonitor,
                statsStore: statsStore,
                terminalManager: terminalManager,
                teamEventDispatcher: dispatcher
            )
            switch result {
            case .failure(let err):
                if let msg = err.userMessage {
                    let alert = NSAlert()
                    alert.messageText = "Could not create worktree"
                    alert.informativeText = msg
                    alert.alertStyle = .warning
                    alert.runModal()
                } else if case .discoveryFailed(let m) = err {
                    NSLog("[Graftty] addWorktree: post-success discover failed for %@: %@",
                          repo.path, m)
                }
            case .success(let outcome):
                selectWorktree(outcome.worktreePath)
                // Roster signal flows through the inbox: a
                // team_member_joined row addressed to the lead is appended
                // by TeamMembershipEvents on add, no live broadcast needed.
            }
        }
        return nil
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
            alert.messageText = "\(URL(fileURLWithPath: path).lastPathComponent) isn't a git repository"
            alert.informativeText = "Initialize git in this folder, or add it as a non-git project."
            alert.alertStyle = .informational
            for title in AddRepositoryAlert.buttons {
                alert.addButton(withTitle: title)
            }
            switch AddRepositoryAlert.choice(for: alert.runModal()) {
            case .cancel:
                return
            case .initializeGit:
                Task { @MainActor in
                    do {
                        try await GitInit.run(at: path)
                    } catch {
                        AddRepositoryAlert.presentGitInitFailure(path: path, error: error)
                        return
                    }
                    // Re-enter the standard add path so discovery, bookmark
                    // mint, and reconciler all run unchanged. GitInit ran in
                    // the folder so the next detect() returns .repoRoot.
                    self.addPath(path)
                }
            case .addWithoutGit:
                let displayName = URL(fileURLWithPath: path).lastPathComponent
                let bookmark = try? RepoBookmark.mint(atPath: path)
                if bookmark == nil {
                    NSLog("[Graftty] addPath: bookmark mint failed for %@; rename-recovery disabled for this entry", path)
                }
                let repo = AddRepositoryAlert.makeNonGitRepoEntry(
                    atPath: path,
                    displayName: displayName,
                    bookmark: bookmark
                )
                appState.addRepo(repo)
                if let first = repo.worktrees.first {
                    self.selectWorktree(first.path)
                }
            }
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
        guard let host = NSApp.mainWindow else { return }
        let config = SheetAlert.Configuration(
            messageText: "Delete Worktree?",
            informativeText: "This will delete the worktree but not the branch.",
            style: .warning,
            primaryButton: "Delete Worktree",
            secondaryButton: "Cancel"
        )
        SheetAlert.present(config, on: host) { response in
            guard response == .primary else { return }
            performDeleteWorktree(worktreePath)
        }
    }

    private func removeRepoWithConfirmation(_ repo: RepoEntry) {
        guard let host = NSApp.mainWindow else { return }
        let config = SheetAlert.Configuration(
            messageText: "Remove \"\(repo.displayName)\"?",
            informativeText: "This removes the repository from Graftty but does not delete any files from disk.",
            style: .warning,
            primaryButton: "Remove",
            secondaryButton: "Cancel"
        )
        let repoPath = repo.path
        SheetAlert.present(config, on: host) { response in
            guard response == .primary else { return }
            performRemoveRepo(atPath: repoPath)
        }
    }

    /// Implements LAYOUT-4.3. Ordering of (a)–(d) before (e) matches the
    /// orphan-surfaces / orphan-caches contracts in GIT-3.10 / GIT-4.10 /
    /// GIT-3.13 / GIT-3.11. No git is invoked; no on-disk files are
    /// touched. Re-resolves the repo by path because the user-facing
    /// confirmation sheet is now async (GIT-4.19) — `appState.repos`
    /// can mutate during the wait, and a stale snapshot of
    /// `repo.worktrees` would leave any worktree added mid-dialog with
    /// an orphan surface after `appState.removeRepo` drops the entry.
    private func performRemoveRepo(atPath repoPath: String) {
        guard let repo = appState.repos.first(where: { $0.path == repoPath }) else { return }
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
            prStatusStore: prStatusStore,
            remoteBranchStore: remoteBranchStore
        )
        // (d) + (e) `AppState.removeRepo` clears selection when victim.
        appState.removeRepo(atPath: repo.path)
    }

    /// Shared `git worktree remove` + teardown path used by both the
    /// user-initiated "Delete Worktree" menu action and the PR-merged
    /// offer dialog. Callers own the confirmation UX — this helper runs
    /// git unconditionally and surfaces failures via the same error
    /// alert as the menu path. `force` is set internally on retry from
    /// the GIT-4.4 dialog; see GIT-4.12.
    private func performDeleteWorktree(_ worktreePath: String, force: Bool = false) {
        Task { @MainActor in
            let result = await DeleteWorktreeFlow.delete(
                worktreePath: worktreePath,
                force: force,
                appState: $appState,
                terminalManager: terminalManager,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                teamEventDispatcher: teamEventDispatcher
            )
            switch result {
            case .success:
                return
            case .failure(.notFound), .failure(.mainCheckoutRejected):
                // UI gating already prevents these; silently no-op
                // matches the pre-refactor behavior.
                return
            case .failure(.gitFailedForceable(let stderr, let status)):
                guard let host = NSApp.mainWindow else { return }
                let config = ForceDeleteAlert.gitFailedForceableConfiguration(stderr: stderr, status: status)
                SheetAlert.present(config, on: host) { response in
                    guard response == .secondary else { return }
                    performDeleteWorktree(worktreePath, force: true)
                }
            case .failure(.gitFailedFinal(let msg)):
                NSLog("[Graftty] performDeleteWorktree: %@", msg)
                guard let host = NSApp.mainWindow else { return }
                let config = ForceDeleteAlert.gitFailedFinalConfiguration(message: msg)
                SheetAlert.present(config, on: host)
            }
        }
    }

    /// Post-remove teardown: destroy live surfaces, clear per-path caches
    /// (GIT-4.10 ordering: BEFORE removing the model entry, so orphan
    /// cache entries don't bleed into a future same-path re-add), drop
    /// the entry, then fire TEAM-5.3 `left`. The TEAM-5.3 lookup uses
    /// `repoPath` rather than `wt.path` because the worktree is gone
    /// from `appState` by the time the lookup runs.
    @MainActor
    private func finishWorktreeRemoval(worktree wt: WorktreeEntry, repoPath: String) {
        if wt.state == .running {
            terminalManager.destroySurfaces(terminalIDs: wt.splitTree.allLeaves)
        }
        prStatusStore.clear(worktreePath: wt.path)
        statsStore.clear(worktreePath: wt.path)
        let leaverBranch = wt.branch
        appState.removeWorktree(atPath: wt.path)
        if let repo = appState.repo(forWorktreePath: repoPath) {
            TeamMembershipEvents.fireLeft(
                repo: repo,
                leaverBranch: leaverBranch,
                leaverPath: wt.path,
                reason: .removed,
                teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled),
                dispatcher: teamEventDispatcher
            )
        }
    }

    /// GIT-4.7 / GIT-4.14. The "offered" marker is persisted via
    /// `AppState.onChange` so Keep is sticky across restarts, not just
    /// across polls — and is written only once we know the sheet is
    /// going up, so a no-window early-return leaves the next poll free
    /// to retry. `beginSheetModal(for:)` (rather than `runModal()`)
    /// keeps the main run loop's default mode pumping so libghostty's
    /// PTY callbacks keep flowing for every embedded pane while the
    /// auto-triggered offer is on screen.
    private func offerDeleteForResolvedPR(worktreePath: String, prNumber: Int, prTitle: String, state: PRInfo.State) {
        guard let (repoIdx, wtIdx) = appState.indices(forWorktreePath: worktreePath) else { return }
        let repo = appState.repos[repoIdx]
        let wt = repo.worktrees[wtIdx]

        // Mirrors GIT-4.1: git refuses to remove the main checkout, and
        // a stale entry has no live worktree to remove.
        guard wt.path != repo.path, wt.state != .stale else { return }
        guard wt.offeredDeleteForResolvedPR != prNumber else { return }
        guard let config = PRResolutionOfferAlert.configuration(prNumber: prNumber, prTitle: prTitle, state: state) else { return }
        // `NSApp.mainWindow` only — falling through to "any visible
        // non-panel window" would attach the sheet to Settings or the
        // Team Activity Log when those are foregrounded. Dropping the
        // offer (and leaving the marker unset) lets the next poll retry.
        guard let host = NSApp.mainWindow else { return }

        // Set the marker now that the sheet is definitely going up, so a
        // user who clicks Keep doesn't get re-prompted on the next poll.
        appState.repos[repoIdx].worktrees[wtIdx].offeredDeleteForResolvedPR = prNumber
        SheetAlert.present(config, on: host) { response in
            guard response == .primary else { return }
            performDeleteWorktree(worktreePath)
        }
    }

    private func movePane(_ terminalID: PaneSlotID, to newPWD: String) {
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
                        let repo = appState.repos[repoIdx]
                        let defaultBranch = remoteBranchStore.resolvedDefaultBranch(
                            forRepoAt: repo.path,
                            hint: repo.defaultBranchHint
                        )
                        let label = SidebarWorktreeLabel.text(
                            for: wt,
                            inRepoAtPath: repo.path,
                            siblingPaths: siblingPaths,
                            defaultBranch: defaultBranch
                        )
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

    /// PROJECT-1.3. Runs `GitInit.run` in the repo folder, flips
    /// `isGitTracked` to true, then rediscovers worktrees so the
    /// synthetic single-worktree entry is replaced by the real
    /// `git worktree list --porcelain` result. Surfaces failures via
    /// the same alert style as `addPath`'s init branch.
    private func initializeGitRepositoryInPlace(_ repo: RepoEntry) {
        Task { @MainActor in
            do {
                try await GitInit.run(at: repo.path)
            } catch {
                AddRepositoryAlert.presentGitInitFailure(path: repo.path, error: error)
                return
            }
            // `appState.repos` can mutate during `await` (the user could
            // remove the repo, or a relocate cascade could rewrite paths),
            // so each post-await mutation re-resolves the index by id.
            guard let idx = appState.repos.firstIndex(where: { $0.id == repo.id }) else { return }
            appState.repos[idx].isGitTracked = true

            let updatedRepo = appState.repos[idx]
            let discovered: [DiscoveredWorktree]
            do {
                discovered = try await WorktreeDiscovery.discover(repo: updatedRepo)
            } catch {
                NSLog("[Graftty] initializeGitRepositoryInPlace: discover failed for %@: %@",
                      repo.path, String(describing: error))
                return
            }
            guard let idx2 = appState.repos.firstIndex(where: { $0.id == repo.id }) else { return }
            appState.repos[idx2].worktrees = discovered.map {
                WorktreeEntry(path: $0.path, branch: $0.branch)
            }
            remoteBranchStore.refresh(repoPath: repo.path)
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
            // Capture the main-checkout branch at add time so the sidebar
            // has a stable default-branch label even before the first
            // origin/HEAD poll lands (or for repos with no remote at all).
            let mainCheckoutBranch = discovered.first(where: { $0.path == repoPath })?.branch
            let repo = RepoEntry(
                path: repoPath,
                displayName: displayName,
                worktrees: worktrees,
                bookmark: bookmark,
                defaultBranchHint: mainCheckoutBranch
            )
            appState.addRepo(repo)
            remoteBranchStore.refresh(repoPath: repoPath)

            if let wt = selectWorktree {
                self.selectWorktree(wt)
            } else if let first = worktrees.first {
                self.selectWorktree(first.path)
            }

            // After the repo lands in `appState` so the user sees the
            // new sidebar row before the nudge explains why its PR
            // column will stay empty. `try?` because a transient detect
            // failure means "no nudge", which is the safe default.
            Task.detached {
                guard let origin = try? await GitOriginHost.detect(repoPath: repoPath) else { return }
                await HostCLIInstallNudge.presentIfNeeded(for: origin.provider)
            }
        }
    }
}
