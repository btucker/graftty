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
        case .leaf(let sessionName, _, _, _, _, _):
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
    @State private var openingRemoteTerminals:
        [RemoteTerminalKey: PaneSlotID] = [:]
    @State private var scheduledRemoteTerminalRetries: Set<RemoteTerminalKey> =
        []
    @State private var remoteTerminalSplitTree = SplitTree(root: nil)
    @State private var appIsVisible = true
    @State private var pendingRemoteNotificationActivation:
        RemoteNotificationEvent?
    @State private var pendingRemoteFocusTarget: RemoteWorktreeKey?
    @State private var pendingRemoteSplitFocus: [PendingRemoteSplitFocus] = []
    @State private var pendingRemoteSplitFocusResults:
        [PendingRemoteSplitFocusResult] = []
    @State private var pendingRemoteCloseProjections:
        [RemoteWorktreeKey: PendingRemoteCloseProjection] = [:]
    @State private var pendingRemotePaneControls:
        [PendingRemotePaneControl] = []
    @State private var pendingRemoteMutationOrder: [UUID] = []
    @State private var remoteMutationInFlight: UUID?
    @State private var remotePaneIntentGeneration: UInt64 = 0
    @State private var openingRemoteWorktrees: Set<RemoteWorktreeKey> = []

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
                                suppressPendingRemoteSplitFocus()
                                if let sessionName = remoteSessionName(
                                    for: terminalID
                                ) {
                                    selectedRemotePaneSessionName = sessionName
                                    if let worktreePath =
                                        selectedRemoteWorktreePath {
                                        Task {
                                            await remoteMacsModel.acknowledge(
                                                on: selectedRemoteMac,
                                                worktreePath: worktreePath,
                                                paneSessionName: sessionName
                                            )
                                        }
                                    }
                                }
                                guard let worktreePath =
                                    selectedRemoteWorktreePath else { return }
                                focusRemotePane(
                                    terminalID,
                                    target: RemoteWorktreeKey(
                                        identity: RemoteMacIdentity(
                                            selectedRemoteMac
                                        ),
                                        worktreePath: worktreePath
                                    )
                                )
                            }
                        )
                        .padding(.leading, 6)
                    } else if let identity = selectedRemoteIdentity,
                              let worktreePath = selectedRemoteWorktreePath,
                              openingRemoteWorktrees.contains(
                                RemoteWorktreeKey(
                                    identity: identity,
                                    worktreePath: worktreePath
                                )
                              ) {
                        ProgressView("Starting remote worktree…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            retryPendingRemoteNotificationActivation()
        }
        .onChange(
            of: remoteMacsModel.notificationActivation,
            initial: true
        ) { _, event in
            guard let event else { return }
            activateRemoteNotification(event)
            remoteMacsModel.consumeRemoteNotificationActivation()
        }
        .onDisappear {
            destroyAllRemoteSurfaces()
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
        pendingRemoteFocusTarget = nil
        suppressPendingRemoteSplitFocus()
        setRemoteSurfacesVisible(false)
        destroyAllRemoteSurfaces()
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
                    _ = GrafttyApp.startWorktree(
                        path: path,
                        appState: $appState,
                        terminalManager: terminalManager
                    )
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
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        setRemoteSurfacesVisible(false)
        if let localPath = appState.selectedWorktreePath {
            setWorktreeSurfacesVisible(false, worktreePath: localPath)
        }
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        let identity = RemoteMacIdentity(remoteMac)
        RemoteMacSidebarSelectionReducer.selectRemote(identity, state: &selection)
        pendingRemoteFocusTarget = nil
        suppressPendingRemoteSplitFocus()
        appState.selectedWorktreePath = selection.selectedWorktreePath
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName
        remoteTerminalSplitTree = SplitTree(root: nil)
        if let previousIdentity, let previousWorktreePath {
            destroyRemoteSurfaces(
                identity: previousIdentity,
                worktreePath: previousWorktreePath
            )
        }

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
        let identity = RemoteMacIdentity(remoteMac)
        if remoteMacsModel.worktreePanesByRemote[identity]?.first(where: {
            $0.path == worktreePath && ($0.origin?.relayDepth ?? 0) == 0
        })?.state.isInFlight == true {
            return
        }
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        setRemoteSurfacesVisible(false)
        if let localPath = appState.selectedWorktreePath {
            setWorktreeSurfacesVisible(false, worktreePath: localPath)
        }
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        let target = RemoteWorktreeKey(
            identity: identity,
            worktreePath: worktreePath
        )
        suppressPendingRemoteSplitFocus()
        RemoteMacSidebarSelectionReducer.selectRemoteWorktree(
            identity,
            worktreePath: worktreePath,
            state: &selection
        )
        appState.selectedWorktreePath = selection.selectedWorktreePath
        selectedRemoteIdentity = selection.selectedRemoteIdentity
        selectedRemoteWorktreePath = selection.selectedRemoteWorktreePath
        selectedRemotePaneSessionName = selection.selectedRemotePaneSessionName
        pendingRemoteFocusTarget = target
        if let previousIdentity,
           let previousWorktreePath,
           previousIdentity != identity
            || previousWorktreePath != worktreePath {
            destroyRemoteSurfaces(
                identity: previousIdentity,
                worktreePath: previousWorktreePath
            )
        }
        synchronizeRemoteWorktree(remoteMac: remoteMac, worktreePath: worktreePath)
        if selectedRemoteWorktreeSnapshot?.state == .closed,
           !openingRemoteWorktrees.contains(target) {
            openingRemoteWorktrees.insert(target)
            Task { @MainActor in
                let response = await remoteMacsModel.openWorktree(
                    on: remoteMac,
                    worktreePath: worktreePath
                )
                if let message = response.errorMessage {
                    openingRemoteWorktrees.remove(target)
                    if pendingRemoteFocusTarget == target {
                        pendingRemoteFocusTarget = nil
                    }
                    presentRemoteWorktreeError(message)
                } else if response != .ok {
                    openingRemoteWorktrees.remove(target)
                    presentRemoteWorktreeError(
                        "The remote Mac returned an unexpected response."
                    )
                }
            }
        }
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
        if worktree.state != .stale {
            guard let host = NSApp.mainWindow else { return }
            let config = SheetAlert.Configuration(
                messageText: "Delete Worktree?",
                informativeText:
                    "This will delete the remote worktree but not the branch.",
                style: .warning,
                primaryButton: "Delete Worktree",
                secondaryButton: "Cancel"
            )
            SheetAlert.present(config, on: host) { response in
                guard response == .primary else { return }
                performDeleteRemoteWorktree(remoteMac, worktree: worktree)
            }
            return
        }
        performDeleteRemoteWorktree(remoteMac, worktree: worktree)
    }

    private func performDeleteRemoteWorktree(
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
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        setRemoteSurfacesVisible(false)
        if let localPath = appState.selectedWorktreePath {
            setWorktreeSurfacesVisible(false, worktreePath: localPath)
        }
        var selection = RemoteMacSidebarSelectionState(
            selectedWorktreePath: appState.selectedWorktreePath,
            selectedRemoteIdentity: selectedRemoteIdentity,
            selectedRemoteWorktreePath: selectedRemoteWorktreePath,
            selectedRemotePaneSessionName: selectedRemotePaneSessionName
        )
        let identity = RemoteMacIdentity(remoteMac)
        let target = RemoteWorktreeKey(
            identity: identity,
            worktreePath: worktreePath
        )
        suppressPendingRemoteSplitFocus()
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
        pendingRemoteFocusTarget = target
        if let previousIdentity,
           let previousWorktreePath,
           previousIdentity != identity
            || previousWorktreePath != worktreePath {
            destroyRemoteSurfaces(
                identity: previousIdentity,
                worktreePath: previousWorktreePath
            )
        }

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
                && (event.originFingerprint == nil
                    || $0.fingerprint == event.originFingerprint)
        }) else { return }
        pendingRemoteNotificationActivation = event
        Task { @MainActor in
            do {
                _ = try await remoteMacsModel.connect(to: remoteMac)
                switch activateRemoteNotificationIfAvailable(
                    event,
                    remoteMac: remoteMac
                ) {
                case .activated, .superseded:
                    return
                case .waitingForSnapshot, .targetMissing:
                    selectRemoteMac(remoteMac)
                }
            } catch {
                if pendingRemoteNotificationActivation?.id == event.id {
                    selectRemoteMac(remoteMac)
                }
            }
        }
    }

    private enum RemoteNotificationActivationResult: Equatable {
        case activated
        case waitingForSnapshot
        case targetMissing
        case superseded
    }

    private func activateRemoteNotificationIfAvailable(
        _ event: RemoteNotificationEvent,
        remoteMac: RemoteMac
    ) -> RemoteNotificationActivationResult {
        guard pendingRemoteNotificationActivation?.id == event.id else {
            return .superseded
        }
        let identity = RemoteMacIdentity(remoteMac)
        guard let worktrees = remoteMacsModel.worktreePanesByRemote[identity]
        else {
            return .waitingForSnapshot
        }
        guard let worktree = worktrees.first(where: {
            $0.path == event.worktreeID
        }) else {
            pendingRemoteNotificationActivation = nil
            return .targetMissing
        }
        pendingRemoteNotificationActivation = nil
        if let paneID = event.paneID,
           worktree.layout?.leaves.contains(where: {
               $0.sessionName == paneID
           }) == true {
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
        return .activated
    }

    private func retryPendingRemoteNotificationActivation() {
        guard let event = pendingRemoteNotificationActivation,
              let remoteMac = remoteMacsModel.savedRemoteMacs.first(where: {
                  $0.id == event.origin.deviceID
                      && (event.originFingerprint == nil
                          || $0.fingerprint == event.originFingerprint)
              }) else {
            return
        }
        if activateRemoteNotificationIfAvailable(
            event,
            remoteMac: remoteMac
        ) == .targetMissing {
            selectRemoteMac(remoteMac)
        }
    }

    private struct RemoteTerminalKey: Hashable {
        var identity: RemoteMacIdentity
        var worktreePath: String
        var sessionName: String
    }

    private struct RemoteWorktreeKey: Hashable {
        var identity: RemoteMacIdentity
        var worktreePath: String
    }

    private struct PendingRemoteSplitFocus {
        var id: UUID
        var target: RemoteWorktreeKey
        var sourceSessionName: String
        var direction: PaneControlRequest.SplitDirection
        var existingSessionNames: Set<String>
        var existingSessionOrder: [String]
        var previousZoomedSessionName: String?
        var focusGeneration: UInt64
        var isDispatched = false
        var shouldFocus = true
        var legacySucceeded = false
    }

    private struct PendingRemoteSplitFocusResult {
        var target: RemoteWorktreeKey
        var existingSessionNames: Set<String>
        var expectedSessionName: String?
        var focusGeneration: UInt64
        var projectedSessionOrder: [String]
        var removedSessionName: String?
    }

    private struct PendingRemoteCloseProjection {
        var removedSessionNames: Set<String>
        var projectedSessionOrder: [String]
    }

    private struct PendingRemotePaneControl {
        let id: UUID
        var request: PaneControlRequest
        let remoteMac: RemoteMac
        let target: RemoteWorktreeKey
        let restoreSnapshotOnError: Bool
        let clearViewerZoomOnSuccess: Bool
        var restoreViewerZoomOnError: String?
        var closeProjection: PaneCloseProjection?
        let focusGeneration: UInt64
    }

    private func reconcileRemoteSelection(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]
    ) {
        reconcileRemoteCloseProjections(
            worktreePanesByRemote: worktreePanesByRemote
        )
        resolveLegacyRemoteSplits(
            worktreePanesByRemote: worktreePanesByRemote
        )
        openingRemoteWorktrees = openingRemoteWorktrees.filter { target in
            worktreePanesByRemote[target.identity]?.contains {
                $0.path == target.worktreePath
                    && ($0.origin?.relayDepth ?? 0) == 0
                    && $0.state == .closed
            } == true
        }
        let currentIdentities = Set(worktreePanesByRemote.keys)
        let staleIdentities = Set(remoteTerminalSlots.keys.map(\.identity))
            .subtracting(currentIdentities)
        for identity in staleIdentities {
            destroyRemoteSurfaces(identity: identity)
        }
        let previousIdentity = selectedRemoteIdentity
        let previousWorktreePath = selectedRemoteWorktreePath
        let previousPaneSessionName = selectedRemotePaneSessionName
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
            pendingRemoteFocusTarget = nil
            suppressPendingRemoteSplitFocus()
            if let previousIdentity, let previousWorktreePath {
                destroyRemoteSurfaces(
                    identity: previousIdentity,
                    worktreePath: previousWorktreePath
                )
            }
            remoteTerminalSplitTree = SplitTree(root: nil)
        } else if let remoteMac = selectedRemoteMac,
                  let worktreePath = selection.selectedRemoteWorktreePath {
            let shouldFocusReplacement = previousIdentity
                == selection.selectedRemoteIdentity
                && previousWorktreePath == worktreePath
                && previousPaneSessionName != nil
                && selection.selectedRemotePaneSessionName == nil
            let target = RemoteWorktreeKey(
                identity: RemoteMacIdentity(remoteMac),
                worktreePath: worktreePath
            )
            if shouldFocusReplacement {
                pendingRemoteFocusTarget = target
            }
            synchronizeRemoteWorktree(
                remoteMac: remoteMac,
                worktreePath: worktreePath,
                preferredSessionName: selection.selectedRemotePaneSessionName,
                focusSelection: false
            )
        }
    }

    private func reconcileRemoteCloseProjections(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]
    ) {
        let savedIdentities = Set(
            remoteMacsModel.savedRemoteMacs.map(RemoteMacIdentity.init)
        )
        for target in Array(pendingRemoteCloseProjections.keys) {
            guard savedIdentities.contains(target.identity) else {
                pendingRemoteCloseProjections[target] = nil
                continue
            }
            guard let worktrees = worktreePanesByRemote[target.identity] else {
                // An offline saved Mac has no authoritative snapshot yet.
                continue
            }
            let sessionNames = Set(
                worktrees.first(where: {
                    $0.path == target.worktreePath
                        && ($0.origin?.relayDepth ?? 0) == 0
                })?.layout?.leaves.map(\.sessionName) ?? []
            )
            if pendingRemoteCloseProjections[target]?
                .removedSessionNames.isDisjoint(with: sessionNames) == true {
                pendingRemoteCloseProjections[target] = nil
            }
        }
    }

    private func synchronizeRemoteWorktree(
        remoteMac: RemoteMac,
        worktreePath: String,
        preferredSessionName: String? = nil,
        focusSelection: Bool = true
    ) {
        let identity = RemoteMacIdentity(remoteMac)
        let focusTarget = RemoteWorktreeKey(
            identity: identity,
            worktreePath: worktreePath
        )
        guard let worktree = remoteMacsModel.worktreePanesByRemote[identity]?
            .first(where: {
                $0.path == worktreePath && ($0.origin?.relayDepth ?? 0) == 0
            }) else {
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == focusTarget && $0.removedSessionName != nil
            }
            pendingRemoteCloseProjections[focusTarget] = nil
            if selectedRemoteIdentity == identity,
               selectedRemoteWorktreePath == worktreePath {
                selectedRemotePaneSessionName = nil
            }
            destroyRemoteSurfaces(identity: identity, worktreePath: worktreePath)
            remoteTerminalSplitTree = SplitTree(root: nil)
            return
        }
        guard let layout = worktree.layout else {
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == focusTarget && $0.removedSessionName != nil
            }
            pendingRemoteCloseProjections[focusTarget] = nil
            if selectedRemoteIdentity == identity,
               selectedRemoteWorktreePath == worktreePath {
                selectedRemotePaneSessionName = nil
            }
            destroyRemoteSurfaces(identity: identity, worktreePath: worktreePath)
            remoteTerminalSplitTree = SplitTree(root: nil)
            return
        }

        let sessionNames = Set(layout.leaves.map(\.sessionName))
        if let closeProjection = pendingRemoteCloseProjections[focusTarget],
           closeProjection.removedSessionNames.isDisjoint(
               with: sessionNames
           ) {
            // Every confirmed removal is now authoritative. Focus results
            // can reconcile below; the topology tombstone has done its job.
            pendingRemoteCloseProjections[focusTarget] = nil
        }
        let removedSessionNames =
            pendingRemoteCloseProjections[focusTarget]?
            .removedSessionNames.intersection(sessionNames) ?? []
        let visibleSessionNames =
            sessionNames.subtracting(removedSessionNames)
        let staleKeys = remoteTerminalSlots.keys.filter {
            $0.identity == identity
                && $0.worktreePath == worktreePath
                && !visibleSessionNames.contains($0.sessionName)
        }
        for key in staleKeys {
            if let terminalID = remoteTerminalSlots.removeValue(forKey: key) {
                terminalManager.destroySurface(terminalID: terminalID)
            }
        }

        let zoomedSessionName = remoteTerminalSplitTree.zoomed.flatMap {
            remoteSessionName(for: $0)
        }
        var projectedTree = SplitTree(
            root: RemotePaneLayoutProjection.node(from: layout) {
                remoteTerminalSlot(
                    identity: identity,
                    worktreePath: worktreePath,
                    sessionName: $0
                )
            }
        )
        for removedSessionName in removedSessionNames {
            let removedKey = RemoteTerminalKey(
                identity: identity,
                worktreePath: worktreePath,
                sessionName: removedSessionName
            )
            if let removedID = remoteTerminalSlots.removeValue(
                forKey: removedKey
            ) {
                projectedTree = projectedTree.removing(removedID)
                terminalManager.destroySurface(terminalID: removedID)
            }
        }
        if let zoomedSessionName,
           visibleSessionNames.contains(zoomedSessionName),
           let zoomedID = remoteTerminalSlots[RemoteTerminalKey(
            identity: identity,
            worktreePath: worktreePath,
            sessionName: zoomedSessionName
           )] {
            projectedTree = projectedTree.withZoom(zoomedID)
        }
        remoteTerminalSplitTree = projectedTree
        var newestSplitSessionName: String?
        while let pendingIndex = pendingRemoteSplitFocusResults.firstIndex(
            where: { $0.target == focusTarget }
        ) {
            let pending = pendingRemoteSplitFocusResults[pendingIndex]
            if let removedSessionName = pending.removedSessionName {
                guard !sessionNames.contains(removedSessionName) else {
                    break
                }
                pendingRemoteSplitFocusResults.remove(at: pendingIndex)
                newestSplitSessionName =
                    pending.expectedSessionName.flatMap {
                        visibleSessionNames.contains($0) ? $0 : nil
                    }
                    ?? layout.leaves.lazy.map(\.sessionName).first {
                        visibleSessionNames.contains($0)
                    }
                continue
            }
            let newSessionName: String?
            if let expectedSessionName = pending.expectedSessionName {
                newSessionName = sessionNames.contains(expectedSessionName)
                    ? expectedSessionName
                    : nil
            } else {
                // Compatibility fallback for older hosts that only return
                // `.ok`. Current hosts return the exact created session.
                newSessionName = layout.leaves.lazy.map(\.sessionName)
                    .first(where: {
                        !pending.existingSessionNames.contains($0)
                    })
            }
            guard let newSessionName else { break }
            pendingRemoteSplitFocusResults.remove(at: pendingIndex)
            for index in pendingRemoteSplitFocusResults.indices
            where pendingRemoteSplitFocusResults[index].target == focusTarget {
                pendingRemoteSplitFocusResults[index]
                    .existingSessionNames.insert(
                        newSessionName
                    )
            }
            newestSplitSessionName = newSessionName
        }
        if let newestSplitSessionName {
            selectedRemotePaneSessionName = newestSplitSessionName
            pendingRemoteFocusTarget = focusTarget
        }
        let focusedSession = preferredSessionName.flatMap {
            visibleSessionNames.contains($0) ? $0 : nil
        } ?? selectedRemotePaneSessionName.flatMap {
            visibleSessionNames.contains($0) ? $0 : nil
        } ?? layout.leaves.lazy.map(\.sessionName).first {
            visibleSessionNames.contains($0)
        }
        selectedRemotePaneSessionName = focusedSession

        for leaf in layout.leaves
        where visibleSessionNames.contains(leaf.sessionName) {
            let key = RemoteTerminalKey(
                identity: identity,
                worktreePath: worktreePath,
                sessionName: leaf.sessionName
            )
            guard let terminalID = remoteTerminalSlots[key],
                  terminalManager.view(for: terminalID) == nil,
                  openingRemoteTerminals[key] == nil else {
                continue
            }
            openingRemoteTerminals[key] = terminalID
            Task { @MainActor in
                defer {
                    if openingRemoteTerminals[key] == terminalID {
                        openingRemoteTerminals[key] = nil
                    }
                }
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
                    let backend = RemoteTerminalSurfaceBackend(
                        client: client,
                        onUnexpectedClose: {
                            Task { @MainActor in
                                handleRemoteSurfaceClosed(
                                    source: key,
                                    terminalID: terminalID
                                )
                            }
                        }
                    )
                    guard terminalManager.createSurface(
                        terminalID: terminalID,
                        paneSessionID: PaneSessionID(id: terminalID.id),
                        worktreePath: worktreePath,
                        hostManagedBackend: backend
                    ) != nil else {
                        scheduleRemoteTerminalRetry(
                            source: key,
                            remoteMac: remoteMac
                        )
                        return
                    }
                    let isSelected = selectedRemoteIdentity == identity
                        && selectedRemoteWorktreePath == worktreePath
                    terminalManager.setVisible(
                        isSelected && appIsVisible,
                        for: terminalID
                    )
                    let shouldFocus = focusSelection
                        || pendingRemoteFocusTarget == focusTarget
                    if isSelected
                        && appIsVisible
                        && shouldFocus
                        && selectedRemotePaneSessionName == leaf.sessionName {
                        focusRemotePane(terminalID, target: focusTarget)
                    }
                } catch {
                    NSLog(
                        "[Graftty] failed to open remote terminal %@ on %@: %@",
                        leaf.sessionName,
                        remoteMac.label,
                        String(describing: error)
                    )
                    scheduleRemoteTerminalRetry(
                        source: key,
                        remoteMac: remoteMac
                    )
                }
            }
        }
        setRemoteSurfacesVisible(appIsVisible)
        let shouldFocus = focusSelection
            || pendingRemoteFocusTarget == focusTarget
        if appIsVisible,
           shouldFocus,
           let focusedRemoteTerminalID,
           terminalManager.view(for: focusedRemoteTerminalID) != nil {
            focusRemotePane(
                focusedRemoteTerminalID,
                target: focusTarget
            )
        }
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
        terminalManager.registerHostManagedPaneCommandHandler(
            for: terminalID
        ) {
            handleRemotePaneCommand(
                $0,
                source: key,
                sourceTerminalID: terminalID
            )
        }
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

    private func handleRemotePaneCommand(
        _ command: HostManagedPaneCommand,
        source: RemoteTerminalKey,
        sourceTerminalID: PaneSlotID
    ) {
        guard remoteTerminalSlots[source] == sourceTerminalID else {
            if case .surfaceClosed = command {
                terminalManager.destroySurface(
                    terminalID: sourceTerminalID
                )
            }
            return
        }
        if case .surfaceClosed = command {
            handleRemoteSurfaceClosed(
                source: source,
                terminalID: sourceTerminalID
            )
            return
        }
        guard selectedRemoteIdentity == source.identity,
              selectedRemoteWorktreePath == source.worktreePath,
              let remoteMac = selectedRemoteMac else { return }
        let target = RemoteWorktreeKey(
            identity: source.identity,
            worktreePath: source.worktreePath
        )
        let inheritedFocusResults = pendingRemoteSplitFocusResults.filter {
            $0.target == target
                && $0.focusGeneration == remotePaneIntentGeneration
        }
        let closeProjection = pendingRemoteCloseProjections[target]
        if closeProjection?.projectedSessionOrder.isEmpty == true {
            // The final pane has closed successfully, but polling has not
            // yet published the empty layout. Ignore commands emitted by
            // the stale surface during that response-to-snapshot gap.
            return
        }
        let effectiveSessionName =
            inheritedFocusResults.last?.expectedSessionName
            ?? closeProjection.flatMap {
                $0.projectedSessionOrder.contains(source.sessionName)
                    ? source.sessionName
                    : $0.projectedSessionOrder.first
            }
            ?? source.sessionName
        let projectedSessionOrder =
            inheritedFocusResults.last?.projectedSessionOrder
            ?? closeProjection?.projectedSessionOrder
            ?? remoteTerminalSplitTree.allLeaves.compactMap {
                remoteSessionName(for: $0)
            }
        let projectedSessionNames = Set(projectedSessionOrder)

        switch command {
        case .split(let split):
            let direction: PaneControlRequest.SplitDirection
            switch split {
            case .right:
                direction = .right
            case .down:
                direction = .down
            case .left:
                direction = .left
            case .up:
                direction = .up
            }
            let pending = PendingRemoteSplitFocus(
                id: UUID(),
                target: target,
                sourceSessionName: effectiveSessionName,
                direction: direction,
                existingSessionNames: projectedSessionNames,
                existingSessionOrder: projectedSessionOrder,
                previousZoomedSessionName: nil,
                focusGeneration: remotePaneIntentGeneration
            )
            pendingRemoteSplitFocus.append(pending)
            pendingRemoteMutationOrder.append(pending.id)
            dispatchNextRemoteMutation()

        case .close:
            sendRemotePaneControl(
                .close(target: effectiveSessionName),
                on: remoteMac,
                target: target,
                projectedSessionOrder: projectedSessionOrder
            )

        case .surfaceClosed:
            return

        case .focus(let direction):
            guard let sourceID = remoteTerminalSlots[source],
                  let nextID = remoteTerminalSplitTree.spatialNeighbor(
                    of: sourceID,
                    direction: direction.asSpatial
                  ),
                  let sessionName = remoteSessionName(for: nextID) else {
                return
            }
            if remoteTerminalSplitTree.zoomed != nil {
                remoteTerminalSplitTree =
                    terminalManager.splitPreserveZoomOnNavigation
                    ? remoteTerminalSplitTree.withZoom(nextID)
                    : remoteTerminalSplitTree.withZoom(nil)
            }
            selectRemotePaneSession(
                sessionName,
                terminalID: nextID,
                remoteMac: remoteMac,
                target: target
            )

        case .focusOrder(let forward):
            guard let sourceID = remoteTerminalSlots[source],
                  let currentIndex = remoteTerminalSplitTree.allLeaves
                    .firstIndex(of: sourceID),
                  remoteTerminalSplitTree.allLeaves.count > 1 else {
                return
            }
            let leaves = remoteTerminalSplitTree.allLeaves
            let nextIndex = forward
                ? (currentIndex + 1) % leaves.count
                : (currentIndex - 1 + leaves.count) % leaves.count
            let nextID = leaves[nextIndex]
            guard let sessionName = remoteSessionName(for: nextID) else {
                return
            }
            if remoteTerminalSplitTree.zoomed != nil {
                remoteTerminalSplitTree =
                    terminalManager.splitPreserveZoomOnNavigation
                    ? remoteTerminalSplitTree.withZoom(nextID)
                    : remoteTerminalSplitTree.withZoom(nil)
            }
            selectRemotePaneSession(
                sessionName,
                terminalID: nextID,
                remoteMac: remoteMac,
                target: target
            )

        case .toggleZoom:
            guard let sourceID = remoteTerminalSlots[source] else { return }
            suppressPendingRemoteSplitFocus()
            remoteTerminalSplitTree = remoteTerminalSplitTree.togglingZoom(
                at: sourceID
            )

        case .equalize:
            sendRemotePaneControl(
                .equalize(target: effectiveSessionName),
                on: remoteMac,
                target: target,
                restoreSnapshotOnError: true,
                clearViewerZoomOnSuccess: true
            )

        case let .resize(direction, amount):
            let wireDirection: PaneControlRequest.SplitDirection
            switch direction {
            case .right:
                wireDirection = .right
            case .down:
                wireDirection = .down
            case .left:
                wireDirection = .left
            case .up:
                wireDirection = .up
            }
            let bounds = NSApp.keyWindow?.contentView?.bounds
                ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let extent: CGFloat
            switch direction {
            case .left, .right:
                extent = bounds.width
            case .up, .down:
                extent = bounds.height
            }
            sendRemotePaneControl(
                .resize(
                    target: effectiveSessionName,
                    direction: wireDirection,
                    amount: amount,
                    viewportExtent: UInt32(
                        clamping: max(1, Int(extent.rounded()))
                    )
                ),
                on: remoteMac,
                target: target,
                restoreSnapshotOnError: true,
                clearViewerZoomOnSuccess: true
            )
        }
    }

    private func handleRemoteSurfaceClosed(
        source: RemoteTerminalKey,
        terminalID: PaneSlotID
    ) {
        guard remoteTerminalSlots[source] == terminalID else {
            terminalManager.destroySurface(terminalID: terminalID)
            return
        }
        let shouldRestoreFocus = focusedRemoteTerminalID == terminalID
        openingRemoteTerminals[source] = nil
        remoteTerminalSlots[source] = nil
        terminalManager.destroySurface(terminalID: terminalID)
        guard selectedRemoteIdentity == source.identity,
              selectedRemoteWorktreePath == source.worktreePath,
              let remoteMac = selectedRemoteMac else {
            remoteTerminalSplitTree =
                remoteTerminalSplitTree.removing(terminalID)
            return
        }
        if shouldRestoreFocus {
            pendingRemoteFocusTarget = RemoteWorktreeKey(
                identity: source.identity,
                worktreePath: source.worktreePath
            )
        }
        synchronizeRemoteWorktree(
            remoteMac: remoteMac,
            worktreePath: source.worktreePath,
            focusSelection: shouldRestoreFocus
        )
        scheduleRemoteTerminalRetry(source: source, remoteMac: remoteMac)
    }

    private func scheduleRemoteTerminalRetry(
        source: RemoteTerminalKey,
        remoteMac: RemoteMac
    ) {
        guard !scheduledRemoteTerminalRetries.contains(source) else { return }
        scheduledRemoteTerminalRetries.insert(source)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard scheduledRemoteTerminalRetries.contains(source) else {
                return
            }
            scheduledRemoteTerminalRetries.remove(source)
            guard selectedRemoteIdentity == source.identity,
                  selectedRemoteWorktreePath == source.worktreePath,
                  remoteMacsModel.worktreePanesByRemote[source.identity]?
                    .contains(where: {
                        $0.path == source.worktreePath
                            && $0.layout?.leaves.contains(where: {
                                $0.sessionName == source.sessionName
                            }) == true
                    }) == true,
                  let terminalID = remoteTerminalSlots[source],
                  terminalManager.view(for: terminalID) == nil else {
                return
            }
            synchronizeRemoteWorktree(
                remoteMac: remoteMac,
                worktreePath: source.worktreePath,
                focusSelection: false
            )
        }
    }

    private func selectRemotePaneSession(
        _ sessionName: String,
        terminalID: PaneSlotID,
        remoteMac: RemoteMac,
        target: RemoteWorktreeKey
    ) {
        suppressPendingRemoteSplitFocus()
        selectedRemotePaneSessionName = sessionName
        pendingRemoteFocusTarget = target
        focusRemotePane(terminalID, target: target)
        Task {
            await remoteMacsModel.acknowledge(
                on: remoteMac,
                worktreePath: target.worktreePath,
                paneSessionName: sessionName
            )
        }
    }

    private func sendRemotePaneControl(
        _ request: PaneControlRequest,
        on remoteMac: RemoteMac,
        target: RemoteWorktreeKey,
        pendingSplitID: UUID? = nil,
        restoreSnapshotOnError: Bool = false,
        clearViewerZoomOnSuccess: Bool = false,
        restoreViewerZoomOnError: String? = nil,
        projectedSessionOrder: [String]? = nil,
        deferBehindPendingSplits: Bool = true,
        viewerEffectGeneration: UInt64? = nil,
        completion: (@MainActor (PaneControlResponse) -> Void)? = nil
    ) {
        if deferBehindPendingSplits,
           pendingSplitID == nil {
            let id = UUID()
            let closeProjection: PaneCloseProjection?
            if case .close(let closedSessionName) = request {
                closeProjection = PaneCloseProjection(
                    target: closedSessionName,
                    sessionOrder: projectedSessionOrder
                        ?? remoteTerminalSplitTree.allLeaves.compactMap {
                            remoteSessionName(for: $0)
                        }
                )
            } else {
                closeProjection = nil
            }
            pendingRemotePaneControls.append(PendingRemotePaneControl(
                id: id,
                request: request,
                remoteMac: remoteMac,
                target: target,
                restoreSnapshotOnError: restoreSnapshotOnError,
                clearViewerZoomOnSuccess: clearViewerZoomOnSuccess,
                restoreViewerZoomOnError: restoreViewerZoomOnError,
                closeProjection: closeProjection,
                focusGeneration: remotePaneIntentGeneration
            ))
            pendingRemoteMutationOrder.append(id)
            dispatchNextRemoteMutation()
            return
        }
        let operation = remoteMacsModel.queuePaneControl(
            on: remoteMac,
            request: request
        )
        Task { @MainActor in
            let response = await operation.value
            defer { completion?(response) }
            switch response {
            case .splitCreated(let sessionName):
                if let pendingSplitID,
                   let index = pendingRemoteSplitFocus.firstIndex(
                    where: { $0.id == pendingSplitID }
                   ) {
                    let completed = pendingRemoteSplitFocus.remove(at: index)
                    pendingRemoteMutationOrder.removeAll {
                        $0 == completed.id
                    }
                    if remoteMutationInFlight == completed.id {
                        remoteMutationInFlight = nil
                    }
                    completeRemoteSplit(
                        completed,
                        createdSessionName: sessionName
                    )
                    if selectedRemoteIdentity == target.identity,
                       selectedRemoteWorktreePath == target.worktreePath {
                        synchronizeRemoteWorktree(
                            remoteMac: remoteMac,
                            worktreePath: target.worktreePath,
                            focusSelection: false
                        )
                    }
                    dispatchNextRemoteMutation()
                }
                return
            case .ok:
                if let pendingSplitID,
                   let index = pendingRemoteSplitFocus.firstIndex(
                    where: { $0.id == pendingSplitID }
                   ) {
                    // Released hosts return only `.ok`. Keep this mutation
                    // as the sole dispatched split until its next snapshot
                    // identifies the new leaf, preventing coalesced layouts
                    // from reversing rapid split focus.
                    pendingRemoteSplitFocus[index].legacySucceeded = true
                    scheduleLegacyRemoteSplitTimeout(
                        id: pendingSplitID,
                        target: target
                    )
                    resolveLegacyRemoteSplits(
                        worktreePanesByRemote:
                            remoteMacsModel.worktreePanesByRemote
                    )
                    if selectedRemoteIdentity == target.identity,
                       selectedRemoteWorktreePath == target.worktreePath {
                        synchronizeRemoteWorktree(
                            remoteMac: remoteMac,
                            worktreePath: target.worktreePath,
                            focusSelection: false
                        )
                    }
                } else if clearViewerZoomOnSuccess,
                          viewerEffectGeneration
                            == remotePaneIntentGeneration,
                          selectedRemoteIdentity == target.identity,
                          selectedRemoteWorktreePath
                            == target.worktreePath {
                    remoteTerminalSplitTree =
                        remoteTerminalSplitTree.withZoom(nil)
                }
                return
            case .error(let code, let message):
                var failedPendingSplit: PendingRemoteSplitFocus?
                if let pendingSplitID,
                   let index = pendingRemoteSplitFocus.firstIndex(
                    where: { $0.id == pendingSplitID }
                   ) {
                    failedPendingSplit = pendingRemoteSplitFocus.remove(
                        at: index
                    )
                    pendingRemoteMutationOrder.removeAll {
                        $0 == pendingSplitID
                    }
                    if remoteMutationInFlight == pendingSplitID {
                        remoteMutationInFlight = nil
                    }
                }
                let abortsSplitBatch = code == "cancelled"
                    || code == "downstream-unavailable"
                var transferredRollback = false
                if !abortsSplitBatch,
                   let failedPendingSplit,
                   let rollbackZoom =
                    failedPendingSplit.previousZoomedSessionName,
                   let nextMutationID =
                    pendingRemoteMutationOrder.first,
                   let nextIndex = pendingRemoteSplitFocus.firstIndex(
                    where: {
                        $0.id == nextMutationID
                            && $0.target == failedPendingSplit.target
                            && $0.previousZoomedSessionName == nil
                    }
                   ) {
                    pendingRemoteSplitFocus[nextIndex]
                        .previousZoomedSessionName = rollbackZoom
                    transferredRollback = true
                }
                var rollbackCandidates = failedPendingSplit.map { [$0] } ?? []
                if abortsSplitBatch {
                    rollbackCandidates.append(contentsOf:
                        pendingRemoteSplitFocus.filter { $0.target == target }
                    )
                    let abandonedIDs = Set(
                        pendingRemoteSplitFocus
                            .filter { $0.target == target }
                            .map(\.id)
                        + pendingRemotePaneControls
                            .filter { $0.target == target }
                            .map(\.id)
                    )
                    pendingRemoteSplitFocus.removeAll { $0.target == target }
                    pendingRemoteSplitFocusResults.removeAll {
                        $0.target == target
                    }
                    pendingRemotePaneControls.removeAll {
                        $0.target == target
                    }
                    pendingRemoteMutationOrder.removeAll {
                        abandonedIDs.contains($0)
                    }
                    if let inFlight = remoteMutationInFlight,
                       abandonedIDs.contains(inFlight) {
                        remoteMutationInFlight = nil
                    }
                }
                if let rollback = rollbackCandidates.first(where: {
                    $0.shouldFocus && $0.previousZoomedSessionName != nil
                }),
                   let previousZoomedSessionName =
                    rollback.previousZoomedSessionName,
                   (abortsSplitBatch || !transferredRollback),
                   remoteTerminalSplitTree.zoomed == nil,
                   selectedRemoteIdentity == target.identity,
                   selectedRemoteWorktreePath == target.worktreePath,
                   let zoomedID = remoteTerminalSlots[RemoteTerminalKey(
                       identity: target.identity,
                       worktreePath: target.worktreePath,
                       sessionName: previousZoomedSessionName
                   )] {
                    remoteTerminalSplitTree =
                        remoteTerminalSplitTree.withZoom(zoomedID)
                }
                if restoreSnapshotOnError,
                   selectedRemoteIdentity == target.identity,
                   selectedRemoteWorktreePath == target.worktreePath {
                    synchronizeRemoteWorktree(
                        remoteMac: remoteMac,
                        worktreePath: target.worktreePath,
                        focusSelection: false
                    )
                    if viewerEffectGeneration
                        == remotePaneIntentGeneration,
                       let restoreViewerZoomOnError,
                       let zoomedID = remoteTerminalSlots[RemoteTerminalKey(
                        identity: target.identity,
                        worktreePath: target.worktreePath,
                        sessionName: restoreViewerZoomOnError
                       )] {
                        remoteTerminalSplitTree =
                            remoteTerminalSplitTree.withZoom(zoomedID)
                    }
                }
                if code != "no-matching-split" && code != "cancelled" {
                    presentRemoteWorktreeError(message)
                }
                if failedPendingSplit != nil {
                    dispatchNextRemoteMutation()
                }
            }
        }
    }

    private func scheduleLegacyRemoteSplitTimeout(
        id: UUID,
        target: RemoteWorktreeKey
    ) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard remoteMutationInFlight == id,
                  pendingRemoteSplitFocus.contains(where: {
                      $0.id == id && $0.legacySucceeded
                  }) else {
                return
            }
            let abandonedIDs = Set(
                pendingRemoteSplitFocus
                    .filter { $0.target == target }
                    .map(\.id)
                + pendingRemotePaneControls
                    .filter { $0.target == target }
                    .map(\.id)
            )
            pendingRemoteSplitFocus.removeAll { $0.target == target }
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == target
            }
            pendingRemotePaneControls.removeAll { $0.target == target }
            pendingRemoteMutationOrder.removeAll {
                abandonedIDs.contains($0)
            }
            remoteMutationInFlight = nil
            dispatchNextRemoteMutation()
        }
    }

    private func dispatchNextRemoteMutation() {
        guard remoteMutationInFlight == nil,
              let id = pendingRemoteMutationOrder.first else {
            return
        }
        if let index = pendingRemoteSplitFocus.firstIndex(where: {
            $0.id == id
        }) {
            pendingRemoteSplitFocus[index].isDispatched = true
            let ownsViewerState =
                pendingRemoteSplitFocus[index].shouldFocus
                && pendingRemoteSplitFocus[index].focusGeneration
                    == remotePaneIntentGeneration
                && selectedRemoteIdentity
                    == pendingRemoteSplitFocus[index].target.identity
                && selectedRemoteWorktreePath
                    == pendingRemoteSplitFocus[index].target.worktreePath
            if ownsViewerState {
                if pendingRemoteSplitFocus[index]
                    .previousZoomedSessionName == nil {
                    pendingRemoteSplitFocus[index]
                        .previousZoomedSessionName =
                        remoteTerminalSplitTree.zoomed.flatMap {
                            remoteSessionName(for: $0)
                        }
                }
                remoteTerminalSplitTree =
                    remoteTerminalSplitTree.withZoom(nil)
            }
            let pending = pendingRemoteSplitFocus[index]
            guard let remoteMac = remoteMacsModel.savedRemoteMacs.first(
                where: {
                    RemoteMacIdentity($0) == pending.target.identity
                }
            ) else {
                pendingRemoteSplitFocus.remove(at: index)
                pendingRemoteMutationOrder.removeFirst()
                dispatchNextRemoteMutation()
                return
            }
            remoteMutationInFlight = id
            sendRemotePaneControl(
                .split(
                    target: pending.sourceSessionName,
                    direction: pending.direction
                ),
                on: remoteMac,
                target: pending.target,
                pendingSplitID: pending.id,
                deferBehindPendingSplits: false
            )
        } else if let index = pendingRemotePaneControls.firstIndex(where: {
            $0.id == id
        }) {
            var pending = pendingRemotePaneControls[index]
            let ownsViewerState =
                pending.focusGeneration == remotePaneIntentGeneration
                && selectedRemoteIdentity == pending.target.identity
                && selectedRemoteWorktreePath
                    == pending.target.worktreePath
            if case .equalize = pending.request, ownsViewerState {
                pending.restoreViewerZoomOnError =
                    remoteTerminalSplitTree.zoomed.flatMap {
                        remoteSessionName(for: $0)
                    }
                remoteTerminalSplitTree =
                    remoteTerminalSplitTree.equalizing()
                pendingRemotePaneControls[index] = pending
            }
            remoteMutationInFlight = id
            sendRemotePaneControl(
                pending.request,
                on: pending.remoteMac,
                target: pending.target,
                restoreSnapshotOnError: pending.restoreSnapshotOnError,
                clearViewerZoomOnSuccess:
                    pending.clearViewerZoomOnSuccess,
                restoreViewerZoomOnError:
                    pending.restoreViewerZoomOnError,
                deferBehindPendingSplits: false,
                viewerEffectGeneration: pending.focusGeneration
            ) { response in
                completeRemotePaneControl(
                    pending,
                    response: response
                )
            }
        } else {
            pendingRemoteMutationOrder.removeFirst()
            dispatchNextRemoteMutation()
        }
    }

    private func completeRemoteSplit(
        _ completed: PendingRemoteSplitFocus,
        createdSessionName: String?
    ) {
        for index in pendingRemoteSplitFocus.indices
        where pendingRemoteSplitFocus[index].target == completed.target {
            // Any successful split commits the batch's local unzoom.
            pendingRemoteSplitFocus[index].previousZoomedSessionName = nil
            if let createdSessionName {
                pendingRemoteSplitFocus[index].existingSessionNames.insert(
                    createdSessionName
                )
                pendingRemoteSplitFocus[index].existingSessionOrder =
                    PaneCloseProjection.sessionOrder(
                        pendingRemoteSplitFocus[index].existingSessionOrder,
                        afterSplitting: completed.sourceSessionName,
                        created: createdSessionName,
                        direction: completed.direction
                    )
                // The exact created ID lets rapid commands follow local
                // focus-after-split semantics without waiting for polling.
                if pendingRemoteSplitFocus[index].focusGeneration
                    == completed.focusGeneration,
                   pendingRemoteSplitFocus[index].sourceSessionName
                    == completed.sourceSessionName {
                    pendingRemoteSplitFocus[index].sourceSessionName =
                        createdSessionName
                }
            }
        }
        if let createdSessionName {
            for index in pendingRemotePaneControls.indices
            where pendingRemotePaneControls[index].target
                == completed.target {
                if var projection =
                    pendingRemotePaneControls[index].closeProjection {
                    let inheritsFocus =
                        pendingRemotePaneControls[index].focusGeneration
                            == completed.focusGeneration
                    projection.projectSplit(
                        from: completed.sourceSessionName,
                        to: createdSessionName,
                        direction: completed.direction,
                        inheritsFocus: inheritsFocus
                    )
                    pendingRemotePaneControls[index].closeProjection =
                        projection
                    pendingRemotePaneControls[index].request = .close(
                        target: projection.target
                    )
                } else if pendingRemotePaneControls[index].focusGeneration
                    == completed.focusGeneration {
                    pendingRemotePaneControls[index].request =
                        pendingRemotePaneControls[index].request
                        .rebasingTarget(
                            from: completed.sourceSessionName,
                            to: createdSessionName
                        )
                }
            }
            if var closeProjection =
                pendingRemoteCloseProjections[completed.target] {
                closeProjection.projectedSessionOrder =
                    PaneCloseProjection.sessionOrder(
                        closeProjection.projectedSessionOrder,
                        afterSplitting: completed.sourceSessionName,
                        created: createdSessionName,
                        direction: completed.direction
                    ).filter {
                        !closeProjection.removedSessionNames.contains($0)
                    }
                pendingRemoteCloseProjections[completed.target] =
                    closeProjection
            }
        }
        guard completed.shouldFocus else { return }
        let projectedSessionOrder: [String]
        if let createdSessionName {
            projectedSessionOrder = PaneCloseProjection.sessionOrder(
                completed.existingSessionOrder,
                afterSplitting: completed.sourceSessionName,
                created: createdSessionName,
                direction: completed.direction
            )
        } else {
            projectedSessionOrder = completed.existingSessionOrder
        }
        pendingRemoteSplitFocusResults.append(
            PendingRemoteSplitFocusResult(
                target: completed.target,
                existingSessionNames: completed.existingSessionNames,
                expectedSessionName: createdSessionName,
                focusGeneration: completed.focusGeneration,
                projectedSessionOrder: projectedSessionOrder,
                removedSessionName: nil
            )
        )
    }

    private func resolveLegacyRemoteSplits(
        worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]]
    ) {
        let candidates = pendingRemoteSplitFocus.filter {
            $0.isDispatched && $0.legacySucceeded
        }
        for candidate in candidates {
            guard let index = pendingRemoteSplitFocus.firstIndex(
                where: { $0.id == candidate.id }
            ),
            let layout = worktreePanesByRemote[candidate.target.identity]?
                .first(where: {
                    $0.path == candidate.target.worktreePath
                        && ($0.origin?.relayDepth ?? 0) == 0
                })?.layout,
            (pendingRemoteCloseProjections[candidate.target]?
                .removedSessionNames.isDisjoint(
                    with: Set(layout.leaves.map(\.sessionName))
                ) ?? true),
            let newSessionName = layout.leaves.lazy.map(\.sessionName)
                .first(where: {
                    !candidate.existingSessionNames.contains($0)
                }),
            remoteMacsModel.savedRemoteMacs.contains(where: {
                RemoteMacIdentity($0) == candidate.target.identity
            }) else {
                continue
            }
            let completed = pendingRemoteSplitFocus.remove(at: index)
            pendingRemoteMutationOrder.removeAll {
                $0 == completed.id
            }
            if remoteMutationInFlight == completed.id {
                remoteMutationInFlight = nil
            }
            completeRemoteSplit(
                completed,
                createdSessionName: newSessionName
            )
            dispatchNextRemoteMutation()
        }
    }

    private func completeRemotePaneControl(
        _ completed: PendingRemotePaneControl,
        response: PaneControlResponse
    ) {
        pendingRemotePaneControls.removeAll { $0.id == completed.id }
        pendingRemoteMutationOrder.removeAll { $0 == completed.id }
        if remoteMutationInFlight == completed.id {
            remoteMutationInFlight = nil
        }
        if response.isSuccess,
           case .close(let closedSessionName) = completed.request,
           let completedProjection = completed.closeProjection {
            let replacement = completedProjection.replacementTarget
            var closeProjection = pendingRemoteCloseProjections[
                completed.target
            ] ?? PendingRemoteCloseProjection(
                removedSessionNames: [],
                projectedSessionOrder: completedProjection.sessionOrder
            )
            closeProjection.removedSessionNames.insert(closedSessionName)
            closeProjection.projectedSessionOrder =
                completedProjection.sessionOrder.filter {
                    !closeProjection.removedSessionNames.contains($0)
                }
            pendingRemoteCloseProjections[completed.target] = closeProjection
            pendingRemoteSplitFocusResults.removeAll {
                $0.target == completed.target
                    && $0.focusGeneration == completed.focusGeneration
            }
            if selectedRemoteIdentity == completed.target.identity,
               selectedRemoteWorktreePath
                == completed.target.worktreePath {
                let currentGeneration = remotePaneIntentGeneration
                let currentProjection =
                    pendingRemoteSplitFocusResults.last(where: {
                        $0.target == completed.target
                            && $0.focusGeneration == currentGeneration
                    })
                let projectedSessionOrder =
                    closeProjection.projectedSessionOrder
                let currentSessionName =
                    currentProjection?.expectedSessionName
                    ?? selectedRemotePaneSessionName
                let projectedSessionName = currentSessionName.flatMap {
                    $0 != closedSessionName
                        && projectedSessionOrder.contains($0) ? $0 : nil
                } ?? projectedSessionOrder.first
                pendingRemoteSplitFocusResults.removeAll {
                    $0.target == completed.target
                        && $0.focusGeneration == currentGeneration
                }
                pendingRemoteSplitFocusResults.append(
                    PendingRemoteSplitFocusResult(
                        target: completed.target,
                        existingSessionNames: [],
                        expectedSessionName: projectedSessionName,
                        focusGeneration: currentGeneration,
                        projectedSessionOrder: projectedSessionOrder,
                        removedSessionName: closedSessionName
                    )
                )
                selectedRemotePaneSessionName = projectedSessionName
                pendingRemoteFocusTarget = completed.target
                let closedKey = RemoteTerminalKey(
                    identity: completed.target.identity,
                    worktreePath: completed.target.worktreePath,
                    sessionName: closedSessionName
                )
                if let closedID = remoteTerminalSlots[closedKey] {
                    remoteTerminalSplitTree =
                        remoteTerminalSplitTree.removing(closedID)
                    terminalManager.setVisible(false, for: closedID)
                }
                if let projectedSessionName,
                   let replacementID = remoteTerminalSlots[
                    RemoteTerminalKey(
                    identity: completed.target.identity,
                    worktreePath: completed.target.worktreePath,
                    sessionName: projectedSessionName
                    )
                ] {
                    focusRemotePane(
                        replacementID,
                        target: completed.target
                    )
                }
            }
            for index in pendingRemoteSplitFocus.indices
            where pendingRemoteSplitFocus[index].target
                == completed.target {
                pendingRemoteSplitFocus[index].existingSessionOrder.removeAll {
                    $0 == closedSessionName
                }
                if let replacement,
                   pendingRemoteSplitFocus[index].sourceSessionName
                    == closedSessionName {
                    pendingRemoteSplitFocus[index].sourceSessionName =
                        replacement
                }
            }
            for index in pendingRemotePaneControls.indices
            where pendingRemotePaneControls[index].target
                == completed.target {
                if var projection =
                    pendingRemotePaneControls[index].closeProjection {
                    projection.projectClose(
                        from: closedSessionName,
                        to: replacement,
                        inheritsFocus: true
                    )
                    pendingRemotePaneControls[index].closeProjection =
                        projection
                    pendingRemotePaneControls[index].request = .close(
                        target: projection.target
                    )
                } else if let replacement {
                    pendingRemotePaneControls[index].request =
                        pendingRemotePaneControls[index].request
                        .rebasingTarget(
                            from: closedSessionName,
                            to: replacement
                        )
                }
            }
            if replacement == nil {
                let doomedSplitIDs = pendingRemoteSplitFocus
                    .filter {
                        $0.target == completed.target
                            && $0.sourceSessionName
                                == closedSessionName
                    }
                    .map(\.id)
                let doomedControlIDs = pendingRemotePaneControls
                    .filter {
                        $0.target == completed.target
                            && $0.request.rebasingTarget(
                                from: closedSessionName,
                                to: "__closed-pane__"
                            ) != $0.request
                    }
                    .map(\.id)
                let doomedIDs = Set(
                    doomedSplitIDs + doomedControlIDs
                )
                pendingRemoteSplitFocus.removeAll {
                    doomedIDs.contains($0.id)
                }
                pendingRemotePaneControls.removeAll {
                    doomedIDs.contains($0.id)
                }
                pendingRemoteMutationOrder.removeAll {
                    doomedIDs.contains($0)
                }
            }
        }
        dispatchNextRemoteMutation()
    }

    private func suppressPendingRemoteSplitFocus() {
        remotePaneIntentGeneration &+= 1
        for index in pendingRemoteSplitFocus.indices {
            pendingRemoteSplitFocus[index].shouldFocus = false
            pendingRemoteSplitFocus[index].previousZoomedSessionName = nil
        }
        pendingRemoteSplitFocusResults.removeAll()
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
            scheduledRemoteTerminalRetries.remove(key)
            openingRemoteTerminals[key] = nil
            if let terminalID = remoteTerminalSlots.removeValue(forKey: key) {
                terminalManager.destroySurface(terminalID: terminalID)
            }
        }
    }

    private func destroyRemoteSurfaces(identity: RemoteMacIdentity) {
        let worktreePaths = Set(remoteTerminalSlots.keys.compactMap {
            $0.identity == identity ? $0.worktreePath : nil
        })
        for worktreePath in worktreePaths {
            destroyRemoteSurfaces(
                identity: identity,
                worktreePath: worktreePath
            )
        }
    }

    private func destroyAllRemoteSurfaces() {
        for terminalID in remoteTerminalSlots.values {
            terminalManager.destroySurface(terminalID: terminalID)
        }
        remoteTerminalSlots.removeAll()
        openingRemoteTerminals.removeAll()
        scheduledRemoteTerminalRetries.removeAll()
        remoteTerminalSplitTree = SplitTree(root: nil)
    }

    private func setWorktreeSurfacesVisible(_ visible: Bool, worktreePath: String) {
        guard let wt = appState.worktree(forPath: worktreePath), wt.state == .running else { return }
        for terminalID in wt.splitTree.allLeaves {
            terminalManager.setVisible(visible, for: terminalID)
        }
    }

    private func applyAppVisibility(isVisible: Bool) {
        appIsVisible = isVisible
        if selectedRemoteWorktreePath != nil {
            setRemoteSurfacesVisible(isVisible)
            if isVisible,
               let remoteMac = selectedRemoteMac,
               let worktreePath = selectedRemoteWorktreePath {
                synchronizeRemoteWorktree(
                    remoteMac: remoteMac,
                    worktreePath: worktreePath,
                    focusSelection: false
                )
            }
            return
        }
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
    private func makePaneFirstResponder(
        _ terminalID: PaneSlotID,
        when shouldFocus: (() -> Bool)? = nil,
        onFocused: (() -> Void)? = nil
    ) {
        let tm = terminalManager
        DispatchQueue.main.async {
            guard !NSApp.isHidden,
                  shouldFocus?() ?? true,
                  let view = tm.view(for: terminalID),
                  let window = view.window else { return }
            tm.setVisible(true, for: terminalID)
            guard window.makeFirstResponder(view) else { return }
            onFocused?()
        }
    }

    private func focusRemotePane(
        _ terminalID: PaneSlotID,
        target: RemoteWorktreeKey
    ) {
        guard selectedRemoteIdentity == target.identity,
              selectedRemoteWorktreePath == target.worktreePath,
              focusedRemoteTerminalID == terminalID else { return }
        terminalManager.setFocus(terminalID)
        makePaneFirstResponder(
            terminalID,
            when: {
                selectedRemoteIdentity == target.identity
                    && selectedRemoteWorktreePath == target.worktreePath
                    && focusedRemoteTerminalID == terminalID
            }
        ) {
            guard selectedRemoteIdentity == target.identity,
                  selectedRemoteWorktreePath == target.worktreePath,
                  pendingRemoteFocusTarget == target else { return }
            pendingRemoteFocusTarget = nil
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
                teamEventDispatcher: dispatcher,
                terminalStartTiming: .afterViewLayout
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
