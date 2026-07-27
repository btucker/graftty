import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol

private extension WorktreeManagementResponse {
    var errorMessage: String? {
        guard case .error(_, let message, _, _) = self else { return nil }
        return message
    }
}

enum RemotePaneLayoutProjection {
    static func node(
        from layout: PaneLayoutNode,
        slotForSession: (String) -> PaneSlotID
    ) -> SplitTree.Node {
        switch layout {
        case .leaf(let sessionName, _, _, _, _):
            return .leaf(slotForSession(sessionName))
        case let .split(direction, ratio, left, right):
            return .split(.init(
                direction: direction == .horizontal
                    ? .horizontal
                    : .vertical,
                ratio: ratio,
                left: node(from: left, slotForSession: slotForSession),
                right: node(from: right, slotForSession: slotForSession)
            ))
        }
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
    @ObservedObject var hostPairingCoordinator: RemoteMacHostPairingCoordinator
    @ObservedObject var remoteMacsModel: RemoteMacsModel
    let makeRemoteMacPairingDriver: () -> AddRemoteMacPairingDriving

    @EnvironmentObject private var updaterController: UpdaterController

    /// Column visibility state — must be a real `@State` rather than a
    /// `.constant(...)` so the toolbar toggle button actually toggles.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Lifted from SidebarView so the ⌘T command handler (scoped to the
    /// SwiftUI scene commands block, which can't reach view-local state)
    /// can present the Add Worktree sheet pre-scoped to the current repo.
    @State private var pendingAddWorktree: AddWorktreeRequest?
    @State private var isShowingAddRemoteMacSheet = false
    @State private var pendingAddRemoteWorktree: RemoteAddWorktreeRequest?
    @State private var selectedRemoteIdentity: RemoteMacIdentity?
    @State private var selectedRemoteWorktreePath: String?
    @State private var selectedRemotePaneSessionName: String?
    @State private var remoteTerminalSlots: [RemoteTerminalKey: PaneSlotID] = [:]
    @State private var remoteTerminalSplitTree = SplitTree(root: nil)

    private struct RemoteAddWorktreeRequest: Identifiable {
        let id = UUID()
        let remoteMac: RemoteMac
        let repository: RemoteRepositoryInfo
    }

    /// GIT-4.20: resolved-PR "delete worktree?" offers that fired while
    /// no window could host the sheet, kept for retry when one appears.
    @State private var pendingResolvedOffers = PendingResolvedOfferQueue()

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
                remoteMacsModel: remoteMacsModel,
                selectedRemoteIdentity: selectedRemoteIdentity,
                selectedRemoteWorktreePath: selectedRemoteWorktreePath,
                selectedRemotePaneSessionName: selectedRemotePaneSessionName,
                onSelect: selectWorktree,
                onSelectPane: selectPane,
                onSelectRemoteMac: selectRemoteMac,
                onSelectRemoteWorktree: selectRemoteWorktree,
                onSelectRemotePane: selectRemotePane,
                onAddRemoteWorktree: beginAddRemoteWorktree,
                onDeleteRemoteWorktree: deleteRemoteWorktree,
                onAddRemoteMac: { isShowingAddRemoteMacSheet = true },
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
                BreadcrumbBar(
                    repoName: selectedRemoteWorktreeSnapshot?.repoDisplayName
                        ?? selectedRepo?.displayName,
                    worktreeDisplayName:
                        selectedRemoteWorktreeSnapshot?.displayName
                        ?? worktreeDisplayName,
                    worktreePath: selectedRemoteWorktreeSnapshot?.path
                        ?? selectedWorktree?.path,
                    branchName: selectedRemoteWorktreeSnapshot?.displayBranch
                        ?? selectedWorktree?.displayBranch,
                    isHomeCheckout:
                        selectedRemoteWorktreeSnapshot?.isMainCheckout
                        ?? isHomeCheckout,
                    prInfo: selectedRemoteWorktreeSnapshot == nil
                        ? prInfo
                        : nil,
                    theme: terminalManager.theme,
                    sidebarHidden: columnVisibility == .detailOnly,
                    onRefreshPR: refreshPR
                )

                if let selectedRemoteMac {
                    if selectedRemoteWorktreePath != nil,
                       remoteTerminalSplitTree.root != nil {
                        TerminalContentView(
                            terminalManager: terminalManager,
                            splitTree: $remoteTerminalSplitTree,
                            focusedPaneSlotID: focusedRemoteTerminalID,
                            theme: terminalManager.theme,
                            onFocusTerminal: { terminalID in
                                if let sessionName = remoteSessionName(
                                    for: terminalID
                                ) {
                                    selectedRemotePaneSessionName = sessionName
                                }
                                terminalManager.setFocus(terminalID)
                            }
                        )
                        .padding(.leading, 6)
                    } else {
                        ContentUnavailableView(
                            selectedRemoteMac.label,
                            systemImage: "laptopcomputer.and.arrow.down",
                            description: Text(selectedRemoteMac.lastKnownBaseURL?.absoluteString ?? "Remote Mac selected.")
                        )
                    }
                } else if let worktree = selectedWorktreeBinding {
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
            .ignoresSafeArea(.container, edges: .top)
        }
        // Tint the NSWindow to match the terminal theme: background color,
        // transparent titlebar + full-size content view, and NSAppearance
        // matching the theme's dark/light-ness so system chrome (traffic
        // lights, context menus, alerts) renders with correct contrast.
        .windowBackgroundTint(theme: terminalManager.theme)
        .installUpdateBadgeAccessory(controller: updaterController)
        .sheet(item: remotePairingRequestBinding) { request in
            RemotePairingRequestSheet(
                request: request,
                onAccept: {
                    Task {
                        // Surface a failed confirm (peer-store write error,
                        // nonce expired between display and tap). Otherwise
                        // `refreshPendingRequest` just clears `pendingRequest`
                        // and the sheet vanishes exactly as if it succeeded.
                        if case .failure(let error) = await hostPairingCoordinator.confirm() {
                            presentRemotePairingConfirmFailure(error)
                        }
                    }
                },
                onDeny: {
                    Task { await hostPairingCoordinator.deny() }
                }
            )
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $isShowingAddRemoteMacSheet) {
            AddRemoteMacSheet(
                model: remoteMacsModel,
                makePairingDriver: makeRemoteMacPairingDriver,
                onCancel: { isShowingAddRemoteMacSheet = false },
                onPaired: { isShowingAddRemoteMacSheet = false }
            )
        }
        .sheet(item: $pendingAddRemoteWorktree) { request in
            AddWorktreeSheet(
                repoDisplayName: "\(request.repository.displayName) on \(request.remoteMac.label)",
                branchEntries: request.repository.branches.map {
                    BranchPickerEntry(
                        name: $0.name,
                        source: $0.source == .local ? .local : .remoteOnly,
                        lastCommitDate: $0.lastCommitDate,
                        mountedWorktreePath: $0.mountedWorktreeID,
                        pr: $0.pullRequest.map {
                            .init(number: $0.number, title: $0.title)
                        }
                    )
                },
                defaultBranchStatus: request.repository.defaultBranchStatus.map {
                    .init(
                        branchName: $0.branchName,
                        remoteRef: $0.remoteRef,
                        behindCount: $0.behindCount
                    )
                },
                onPullDefaultBranch: {
                    let response = await remoteMacsModel.pullDefaultBranch(
                        on: request.remoteMac,
                        repositoryID: request.repository.id
                    )
                    return response.errorMessage
                },
                onSubmit: { worktreeName, branch in
                    let response = await remoteMacsModel.createWorktree(
                        on: request.remoteMac,
                        repositoryID: request.repository.id,
                        worktreeName: worktreeName,
                        branch: branch
                    )
                    if case .created = response {
                        pendingAddRemoteWorktree = nil
                        return nil
                    }
                    return response.errorMessage
                        ?? "The remote Mac returned an unexpected response."
                },
                onCancel: { pendingAddRemoteWorktree = nil }
            )
        }
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
            guard let newPath else { return }
            terminalManager.surfaceBudget.noteSelected(
                worktreePath: newPath,
                splitTreesByPath: appState.runningSplitTreesByPath()
            )
        }
        .onChange(of: remoteMacsModel.worktreePanesByRemote) { _, snapshots in
            reconcileRemoteSelection(worktreePanesByRemote: snapshots)
        }
        .onChange(of: remoteMacsModel.notificationActivation) { _, event in
            guard let event else { return }
            activateRemoteNotification(event)
            remoteMacsModel.consumeRemoteNotificationActivation()
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
        // GIT-4.20: retry any resolved-PR offers that couldn't present
        // when they fired (no host window). Two triggers, because the
        // offer can be enqueued whenever `NSApp.mainWindow` is nil:
        // `didBecomeActive` covers returning from the background (a PR
        // merged while the user was away — the reported case), and
        // `didBecomeMain` covers a window reappearing while the app
        // stayed active (e.g. the primary window was deminiaturized).
        // The retry hosts on `NSApp.mainWindow`, same as every other
        // alert site here — presenting on a non-primary main window is
        // still strictly better than losing the offer, which is what
        // happened before.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            retryPendingResolvedOffers()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
            retryPendingResolvedOffers()
        }
    }

    /// GIT-4.20: re-attempt the resolved-PR "delete worktree?" offers
    /// that were queued while no window could host the sheet. Each retry
    /// re-enters `offerDeleteForResolvedPR`, which re-checks the marker /
    /// stale guards and re-queues itself if a window still isn't ready.
    private func retryPendingResolvedOffers() {
        for offer in pendingResolvedOffers.drain() {
            offerDeleteForResolvedPR(
                worktreePath: offer.worktreePath,
                prNumber: offer.prNumber,
                prTitle: offer.prTitle,
                state: offer.state
            )
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

    private var remotePairingRequestBinding: Binding<PendingRemotePairingRequest?> {
        Binding(
            get: { hostPairingCoordinator.pendingRequest },
            set: { _ in }
        )
    }

    /// The pairing consent sheet dismisses on any terminal outcome, so a
    /// failed Accept (peer-store write failure, or the nonce expiring before
    /// the user tapped) would otherwise be indistinguishable from success.
    @MainActor
    private func presentRemotePairingConfirmFailure(_ error: PairingErrorResponse) {
        let alert = NSAlert()
        alert.messageText = "Could not pair remote Mac"
        alert.informativeText = error.error
        alert.alertStyle = .warning
        alert.runModal()
    }

    private var selectedWorktree: WorktreeEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.worktree(forPath: path)
    }

    private var selectedRemoteMac: RemoteMac? {
        guard let selectedRemoteIdentity else { return nil }
        return remoteMacsModel.savedRemoteMacs.first {
            RemoteMacIdentity($0) == selectedRemoteIdentity
        }
    }

    private var selectedRemoteWorktreeSnapshot: WorktreePanes? {
        guard let identity = selectedRemoteIdentity,
              let path = selectedRemoteWorktreePath else { return nil }
        return remoteMacsModel.worktreePanesByRemote[identity]?.first {
            $0.path == path && ($0.origin?.relayDepth ?? 0) == 0
        }
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
    /// for fixed Option worktree navigation. `nil` when there is nothing
    /// to move to; the fixed menu chords remain registered as no-ops. Routes
    /// through the same `selectWorktree` sidebar clicks use, so surface show/hide and
    /// `acknowledgeAttention()` all fire identically.
    private var worktreeNavAction: ((Bool) -> Void)? {
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
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        RemoteMacSidebarSelectionReducer.selectLocalWorktree(path, state: &selection)
        setRemoteSurfacesVisible(false)
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName
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

    private func selectRemoteMac(_ remoteMac: RemoteMac) {
        setRemoteSurfacesVisible(false)
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        let identity = RemoteMacIdentity(remoteMac)
        RemoteMacSidebarSelectionReducer.selectRemote(identity, state: &selection)
        appState.selectedWorktreePath = selection.selectedWorktreePath
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName
        remoteTerminalSplitTree = SplitTree(root: nil)

        Task { @MainActor in
            do {
                _ = try await remoteMacsModel.connect(to: remoteMac)
                _ = try await remoteMacsModel.refreshRepositories(
                    on: remoteMac
                )
            } catch {
                NSLog("[Graftty] failed to connect remote Mac %@: %@", remoteMac.label, String(describing: error))
            }
        }
    }

    private func selectRemoteWorktree(_ remoteMac: RemoteMac, worktreePath: String) {
        setRemoteSurfacesVisible(false)
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        let identity = RemoteMacIdentity(remoteMac)
        RemoteMacSidebarSelectionReducer.selectRemoteWorktree(
            identity,
            worktreePath: worktreePath,
            state: &selection
        )
        appState.selectedWorktreePath = selection.selectedWorktreePath
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName
        synchronizeRemoteWorktree(remoteMac: remoteMac, worktreePath: worktreePath)
        Task {
            await remoteMacsModel.acknowledge(
                on: remoteMac,
                worktreePath: worktreePath
            )
        }
    }

    private func beginAddRemoteWorktree(
        _ remoteMac: RemoteMac,
        repository: RemoteRepositoryInfo
    ) {
        pendingAddRemoteWorktree = RemoteAddWorktreeRequest(
            remoteMac: remoteMac,
            repository: repository
        )
    }

    private func deleteRemoteWorktree(
        _ remoteMac: RemoteMac,
        worktree: WorktreePanes
    ) {
        Task { @MainActor in
            let response = await remoteMacsModel.deleteWorktree(
                on: remoteMac,
                worktreePath: worktree.path,
                force: false
            )
            guard case let .error(_, message, forceAllowed, shortStatus) = response
            else { return }
            if forceAllowed {
                let alert = NSAlert()
                alert.messageText = "Could not delete worktree"
                alert.informativeText = message
                    + (shortStatus.map { "\n\n\($0)" } ?? "")
                alert.addButton(withTitle: "Force Delete")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return
                }
                let forced = await remoteMacsModel.deleteWorktree(
                    on: remoteMac,
                    worktreePath: worktree.path,
                    force: true
                )
                if let forcedMessage = forced.errorMessage {
                    presentRemoteWorktreeError(forcedMessage)
                }
            } else {
                presentRemoteWorktreeError(message)
            }
        }
    }

    private func presentRemoteWorktreeError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Remote worktree operation failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func selectRemotePane(_ remoteMac: RemoteMac, worktreePath: String, sessionName: String) {
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        let identity = RemoteMacIdentity(remoteMac)
        RemoteMacSidebarSelectionReducer.selectRemotePane(
            identity,
            worktreePath: worktreePath,
            sessionName: sessionName,
            state: &selection
        )
        appState.selectedWorktreePath = selection.selectedWorktreePath
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName

        synchronizeRemoteWorktree(
            remoteMac: remoteMac,
            worktreePath: worktreePath,
            preferredSessionName: sessionName
        )
        Task {
            await remoteMacsModel.acknowledge(
                on: remoteMac,
                worktreePath: worktreePath,
                paneSessionName: sessionName
            )
        }
    }

    private func activateRemoteNotification(_ event: RemoteNotificationEvent) {
        guard let remoteMac = remoteMacsModel.savedRemoteMacs.first(where: {
            $0.id == event.origin.deviceID
        }) else { return }
        if let paneID = event.paneID {
            selectRemotePane(
                remoteMac,
                worktreePath: event.worktreeID,
                sessionName: paneID
            )
        } else {
            selectRemoteWorktree(
                remoteMac,
                worktreePath: event.worktreeID
            )
        }
    }

    private struct RemoteTerminalKey: Hashable {
        var identity: RemoteMacIdentity
        var worktreePath: String
        var sessionName: String
    }

    private func reconcileRemoteSelection(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]
    ) {
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        RemoteMacSidebarSelectionReducer.reconcileRemoteSelection(
            worktreePanesByRemote: worktreePanesByRemote,
            state: &selection
        )

        appState.selectedWorktreePath = selection.selectedWorktreePath
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName

        if selection.selectedRemoteWorktreePath == nil {
            if let previousIdentity, let previousWorktreePath {
                destroyRemoteSurfaces(
                    identity: previousIdentity,
                    worktreePath: previousWorktreePath
                )
            }
            remoteTerminalSplitTree = SplitTree(root: nil)
        } else if let remoteMac = selectedRemoteMac,
                  let worktreePath = selection.selectedRemoteWorktreePath {
            synchronizeRemoteWorktree(
                remoteMac: remoteMac,
                worktreePath: worktreePath,
                preferredSessionName: selection.selectedRemotePaneSessionName
            )
        }
    }

    private func synchronizeRemoteWorktree(
        remoteMac: RemoteMac,
        worktreePath: String,
        preferredSessionName: String? = nil
    ) {
        let identity = RemoteMacIdentity(remoteMac)
        guard let worktree = remoteMacsModel.worktreePanesByRemote[identity]?
            .first(where: {
                $0.path == worktreePath && ($0.origin?.relayDepth ?? 0) == 0
            }),
              let layout = worktree.layout else {
            destroyRemoteSurfaces(identity: identity, worktreePath: worktreePath)
            remoteTerminalSplitTree = SplitTree(root: nil)
            return
        }

        let sessionNames = Set(layout.leaves.map(\.sessionName))
        let staleKeys = remoteTerminalSlots.keys.filter {
            $0.identity == identity
                && $0.worktreePath == worktreePath
                && !sessionNames.contains($0.sessionName)
        }
        for key in staleKeys {
            if let terminalID = remoteTerminalSlots.removeValue(forKey: key) {
                terminalManager.destroySurface(terminalID: terminalID)
            }
        }

        remoteTerminalSplitTree = SplitTree(
            root: RemotePaneLayoutProjection.node(from: layout) {
                remoteTerminalSlot(
                    identity: identity,
                    worktreePath: worktreePath,
                    sessionName: $0
                )
            }
        )
        let focusedSession = preferredSessionName.flatMap {
            sessionNames.contains($0) ? $0 : nil
        } ?? selectedRemotePaneSessionName.flatMap {
            sessionNames.contains($0) ? $0 : nil
        } ?? layout.leaves.first?.sessionName
        selectedRemotePaneSessionName = focusedSession

        for leaf in layout.leaves {
            let key = RemoteTerminalKey(
                identity: identity,
                worktreePath: worktreePath,
                sessionName: leaf.sessionName
            )
            guard let terminalID = remoteTerminalSlots[key],
                  terminalManager.view(for: terminalID) == nil else {
                continue
            }
            Task { @MainActor in
                do {
                    _ = try await remoteMacsModel.connect(to: remoteMac)
                    let client = try await remoteMacsModel.openTerminalSession(
                        identity: identity,
                        sessionName: leaf.sessionName
                    )
                    guard remoteTerminalSlots[key] == terminalID else {
                        client.close()
                        return
                    }
                    let backend = RemoteTerminalSurfaceBackend(client: client)
                    _ = terminalManager.createSurface(
                        terminalID: terminalID,
                        paneSessionID: PaneSessionID(id: terminalID.id),
                        worktreePath: worktreePath,
                        hostManagedBackend: backend
                    )
                    terminalManager.setVisible(true, for: terminalID)
                    if selectedRemotePaneSessionName == leaf.sessionName {
                        terminalManager.setFocus(terminalID)
                    }
                } catch {
                    NSLog(
                        "[Graftty] failed to open remote terminal %@ on %@: %@",
                        leaf.sessionName,
                        remoteMac.label,
                        String(describing: error)
                    )
                }
            }
        }
        setRemoteSurfacesVisible(true)
    }

    private func remoteTerminalSlot(
        identity: RemoteMacIdentity,
        worktreePath: String,
        sessionName: String
    ) -> PaneSlotID {
        let key = RemoteTerminalKey(
            identity: identity,
            worktreePath: worktreePath,
            sessionName: sessionName
        )
        if let existing = remoteTerminalSlots[key] {
            return existing
        }
        let terminalID = PaneSlotID()
        remoteTerminalSlots[key] = terminalID
        return terminalID
    }

    private var focusedRemoteTerminalID: PaneSlotID? {
        guard let identity = selectedRemoteIdentity,
              let worktreePath = selectedRemoteWorktreePath,
              let sessionName = selectedRemotePaneSessionName else {
            return remoteTerminalSplitTree.allLeaves.first
        }
        return remoteTerminalSlots[RemoteTerminalKey(
            identity: identity,
            worktreePath: worktreePath,
            sessionName: sessionName
        )] ?? remoteTerminalSplitTree.allLeaves.first
    }

    private func remoteSessionName(for terminalID: PaneSlotID) -> String? {
        remoteTerminalSlots.first(where: { $0.value == terminalID })?.key.sessionName
    }

    private func setRemoteSurfacesVisible(_ visible: Bool) {
        guard let identity = selectedRemoteIdentity,
              let worktreePath = selectedRemoteWorktreePath else { return }
        for (key, terminalID) in remoteTerminalSlots
        where key.identity == identity && key.worktreePath == worktreePath {
            terminalManager.setVisible(visible, for: terminalID)
        }
    }

    private func destroyRemoteSurfaces(
        identity: RemoteMacIdentity,
        worktreePath: String
    ) {
        let keys = remoteTerminalSlots.keys.filter {
            $0.identity == identity && $0.worktreePath == worktreePath
        }
        for key in keys {
            if let terminalID = remoteTerminalSlots.removeValue(forKey: key) {
                terminalManager.destroySurface(terminalID: terminalID)
            }
        }
    }

    private func setWorktreeSurfacesVisible(_ visible: Bool, worktreePath: String) {
        guard let wt = appState.worktree(forPath: worktreePath), wt.state == .running else { return }
        for terminalID in wt.splitTree.allLeaves {
            terminalManager.setVisible(visible, for: terminalID)
        }
    }

    private func applyAppVisibility(isVisible: Bool) {
        guard let action = AppVisibilitySurfacePolicy.action(
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
                // team_member_joined row addressed to the main worktree is appended
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
        // Team Activity Log when those are foregrounded. GIT-4.20: the
        // store fires the resolved edge exactly once (GIT-4.7 idempotent
        // guard), so we can't rely on "the next poll retries" — queue
        // the offer instead and retry it when a window appears.
        guard let host = NSApp.mainWindow else {
            pendingResolvedOffers.enqueue(PendingResolvedOffer(
                worktreePath: worktreePath, prNumber: prNumber,
                prTitle: prTitle, state: state
            ))
            return
        }

        // The offer is presenting, so it no longer needs to be retried.
        pendingResolvedOffers.remove(worktreePath: worktreePath)
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
