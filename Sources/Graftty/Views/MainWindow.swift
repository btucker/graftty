import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
import GrafttyRemoteClient

private extension WorktreeManagementResponse {
    var errorMessage: String? {
        guard case .error(_, let message, _, _) = self else { return nil }
        return message
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
    @ObservedObject private var iconStore = SidebarHostController.shared
    @ObservedObject private var previewWindows = FilePreviewWindows.shared
    @ObservedObject var remoteMacsModel: RemoteMacsModel
    let appStateChanges: AppStateChanges
    let makeRemoteMacPairingDriver: () throws -> AddRemoteMacPairingDriving

    @EnvironmentObject private var updaterController: UpdaterController

    @State private var showsWorktreeContext = false
    @State private var requestedRemoteAgent: String?
    @State private var sidebarNavigation = SidebarNavigationState(prefix: "sidebar.mac")

    /// Column visibility state — must be a real `@State` rather than a
    /// `.constant(...)` so the toolbar toggle button actually toggles.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Lifted from SidebarView so the ⌘T command handler (scoped to the
    /// SwiftUI scene commands block, which can't reach view-local state)
    /// can present the Add Worktree sheet pre-scoped to the current repo.
    @State private var pendingAddWorktree: AddWorktreeRequest?
    @State private var isShowingAddRemoteMacSheet = false
    @State private var isShowingLinuxHostSetupSheet = false
    @State private var pendingHostMaintenance: LinuxHostMaintenanceRequest?
    @State private var linuxHostSetupClient: LinuxHostTrustRequest?
    @State private var pendingAddRemoteWorktree: RemoteAddWorktreeRequest?
    @State private var worktreeHistory = WorktreeNavigationHistory()
    @State private var attentionOpenGeneration: UInt64 = 0
    @StateObject private var voiceDictation = VoiceDictationController()
    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    @AppStorage("sidebar.mac.collapsed") private var projectRailCollapsed = false
    @AppStorage("sidebar.mac.railWidth") private var projectRailExpandedWidth = 196.0
    private var minimumSidebarWidth: Double {
        (showsProjectRail ? SidebarLayoutPolicy.railWidth(collapsed: projectRailCollapsed, expandedWidth: projectRailExpandedWidth) + 1 : 0) + 220
    }
    @State private var pendingRemoteNotificationActivation:
        RemoteNotificationEvent?
    /// The remote worktree viewer: selection, projected split tree, and the
    /// pane-mutation queue. Created once per window, like the `@State` it
    /// replaced; it publishes only what this view draws (REMOTE-24.13).
    @StateObject private var remoteViewer: RemoteWorktreeViewerController

    init(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        statsStore: WorktreeStatsStore,
        prStatusStore: PRStatusStore,
        claudeSessionRegistry: ClaudeSessionRegistry,
        remoteBranchStore: RemoteBranchStore,
        worktreeMonitor: WorktreeMonitor,
        teamEventDispatcher: TeamEventDispatcher,
        hostPairingCoordinator: RemoteMacHostPairingCoordinator,
        remoteMacsModel: RemoteMacsModel,
        appStateChanges: AppStateChanges,
        makeRemoteMacPairingDriver: @escaping () throws -> AddRemoteMacPairingDriving
    ) {
        _appState = appState
        self.terminalManager = terminalManager
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
        self.claudeSessionRegistry = claudeSessionRegistry
        self.remoteBranchStore = remoteBranchStore
        self.worktreeMonitor = worktreeMonitor
        self.teamEventDispatcher = teamEventDispatcher
        self.hostPairingCoordinator = hostPairingCoordinator
        self.remoteMacsModel = remoteMacsModel
        self.appStateChanges = appStateChanges
        self.makeRemoteMacPairingDriver = makeRemoteMacPairingDriver
        _remoteViewer = StateObject(wrappedValue: RemoteWorktreeViewerController(
            model: remoteMacsModel,
            surfaces: terminalManager
        ))
    }

    private struct RemoteAddWorktreeRequest: Identifiable {
        let id = UUID()
        let remoteMac: RemoteMac
        let repository: RemoteRepositoryInfo
    }

    @ViewBuilder private func remoteWorkspaceContent(for remote: RemoteMac) -> some View {
        if let snapshot = selectedRemoteWorktreeSnapshot {
            RemoteWorkspaceContentView(viewer: remoteViewer, terminalManager: terminalManager,
                worktree: snapshot, identity: RemoteMacIdentity(remote), focused: focusedRemoteTerminalID,
                onFocus: { terminalID in
                    attentionOpenGeneration &+= 1
                    remoteViewer.focusTerminal(terminalID)
                }, agentScrollbackMap: agentScrollbackMap, requestedAgent: requestedRemoteAgent, consumeAgentRequest: { requestedRemoteAgent = nil }, conversationRequest: { id, action in
                    try await remoteMacsModel.sendWorktreeManagement(identity: RemoteMacIdentity(remote),
                        request: .agentConversation(worktreeID: snapshot.path, agentID: id, action: action))
                })
                .id(RemoteWorktreeViewerController.WorktreeKey(identity: RemoteMacIdentity(remote), worktreePath: snapshot.path))
        }
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility
        ) {
            SidebarView(
                appState: $appState,
                terminalManager: terminalManager,
                paneTitleInvalidations: terminalManager.paneTitleInvalidations,
                voiceDictation: voiceDictation,
                selectedVoicePaneID: selectedVoicePaneID,
                theme: terminalManager.theme,
                statsStore: statsStore,
                prStatusStore: prStatusStore,
                claudeSessionRegistry: claudeSessionRegistry,
                remoteBranchStore: remoteBranchStore,
                remoteMacsModel: remoteMacsModel,
                appStateChanges: appStateChanges,
                selectedRemoteIdentity: selectedRemoteIdentity,
                selectedRemoteWorktreePath: selectedRemoteWorktreePath,
                selectedRemotePaneSessionName: selectedRemotePaneSessionName,
                onSelect: selectWorktree,
                onOpenAttention: openAttentionTarget,
                onNavigationIntent: { attentionOpenGeneration &+= 1 },
                onSelectPane: selectPane,
                onSelectRemoteMac: selectRemoteMac,
                onSelectRemoteWorktree: selectRemoteWorktree,
                onSelectRemotePane: selectRemotePane,
                onAddRemoteWorktree: beginAddRemoteWorktree,
                onDeleteRemoteWorktree: deleteRemoteWorktree,
                onAddRemoteMac: { isShowingAddRemoteMacSheet = true },
                onSetupLinuxHost: presentLinuxHostSetup,
                onUpdateHost: { remote in
                    if let pin = remoteMacsModel.maintenanceHost(for: remote) {
                        pendingHostMaintenance = .init(remote: remote, pinnedHost: pin)
                    }
                },
                onAddRepo: addRepository,
                onAddPath: addPath,
                onRemoveRepo: removeRepoWithConfirmation,
                onInitializeGit: initializeGitRepositoryInPlace,
                onStopWorktree: stopWorktreeWithConfirmation,
                onDeleteWorktree: deleteWorktreeWithConfirmation,
                onMovePane: movePane,
                onAddWorktree: addWorktree,
                pendingAddWorktree: $pendingAddWorktree,
                navigation: sidebarNavigation
            )
            .navigationSplitViewColumnWidth(
                min: minimumSidebarWidth,
                ideal: max(minimumSidebarWidth, appState.sidebarWidth),
                max: 676
            )
            // SidebarView opts out of the title-bar safe area itself and
            // places its search row in that strip, inset past the traffic
            // lights and the sidebar toggle; the detail column does the
            // same for the breadcrumb.
        } detail: {
            MainWindowDetailLayout {
                BreadcrumbBar(
                    repoName: selectedRemoteWorktreeSnapshot?.repoDisplayName
                        ?? selectedRepo?.displayName,
                    worktreeDisplayName:
                        selectedRemoteWorktreeSnapshot?.displayName
                        ?? worktreeDisplayName,
                    worktreeEmoji: BreadcrumbBar.selectedWorktreeEmoji(
                        localEmoji: selectedWorktree?.emoji,
                        remoteWorktree: selectedRemoteWorktreeSnapshot
                    ),
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
                    canGoBack: worktreeHistory.target(forward: false, isAvailable: isHistoryTargetAvailable) != nil,
                    canGoForward: worktreeHistory.target(forward: true, isAvailable: isHistoryTargetAvailable) != nil,
                    historyItems: worktreeHistory.recentTargets.compactMap(historyItem),
                    currentTarget: currentNavigationTarget,
                    onGoBack: { navigateWorktreeHistory(forward: false) },
                    onGoForward: { navigateWorktreeHistory(forward: true) },
                    onSelectHistory: selectHistoryTarget,
                    onRefreshPR: refreshPR,
                    project: selectedIdentityProject, projectIconData: selectedProjectIconData,
                    previewWorktreePath: selectedRemoteIdentity == nil ? selectedWorktree?.path : nil,
                    previewInlinePane: selectedWorktree.flatMap { worktree in
                        worktree.presentationPane.flatMap { slot in
                            worktree.visiblePaneSlots.contains(slot) && !worktree.hasCompletedContent(in: slot) ? slot : nil
                        }
                    },
                    previewWorktreeForPane: { [weak terminalManager] pane in terminalManager?.worktreePath(for: pane) },
                    onToggleContext: selectedWorktree != nil || selectedRemoteWorktreeSnapshot != nil ? { showsWorktreeContext.toggle() } : nil,
                    showsContext: showsWorktreeContext
                )
            } content: {
                if let selectedRemoteMac {
                    if let row = selectedRemoteWorktreeSnapshot, row.showsCreationProgress,
                       let progress = row.creationProgress {
                        WorktreeCreationDetailView(progress: progress,
                            foreground: terminalManager.theme.foreground, background: terminalManager.theme.background,
                            onOpenTerminal: row.state == .closed ? {
                                remoteViewer.selectRemoteWorktree(selectedRemoteMac, worktreePath: row.path,
                                    acknowledging: false, inspectingCreation: false)
                            } : nil)
                    } else if selectedRemoteWorktreePath != nil, selectedRemoteWorktreeSnapshot != nil {
                        remoteWorkspaceContent(for: selectedRemoteMac)
                            .padding(.leading, 6)
                    } else if remoteViewer.isOpeningSelectedWorktree {
                        ProgressView("Starting remote worktree…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            selectedRemoteMac.label,
                            systemImage: "laptopcomputer.and.arrow.down",
                            description: Text(selectedRemoteMac.lastKnownBaseURL?.absoluteString ?? "Remote Mac selected.")
                        )
                    }
                } else if let row = selectedWorktree, row.showsCreationProgress,
                          let progress = row.creationProgress {
                    WorktreeCreationDetailView(progress: progress,
                        foreground: terminalManager.theme.foreground, background: terminalManager.theme.background,
                        onOpenTerminal: row.state == .closed ? {
                            _ = selectWorktree(row.path, acknowledging: false, inspectingCreation: false)
                        } : nil)
                } else if let worktree = selectedWorktreeBinding {
                    WorkspaceContentView(
                        terminalManager: terminalManager,
                        worktree: worktree,
                        onFocusTerminal: { terminalID in
                            attentionOpenGeneration &+= 1
                            // Persist the focus change on the model BEFORE
                            // routing to libghostty: `TERM-2.3`'s focus-
                            // restore after a worktree switch reads
                            // `focusedPaneSlotID`, so a mouse-click that
                            // only called `setFocus` (the libghostty side)
                            // used to let focus snap back to the first leaf
                            // on the next return visit.
                            if let wtPath = appState.selectedWorktreePath {
                                appState.setFocusedTerminal(terminalID, forWorktreePath: wtPath)
                                // STATE-2.4: viewing a pane clears notifications;
                                // agent requests remain until provider progress.
                                appState.viewPaneAttention(terminalID, forWorktreePath: wtPath)
                            }
                            terminalManager.setFocus(terminalID)
                        },
                        onNewTerminal: {
                            worktree.wrappedValue.ensureWorkspaceLayout()
                            if let target = worktree.wrappedValue.splitTree.allLeaves.first {
                                if let slot = PaneCommands.splitPane(appState: $appState, terminalManager: terminalManager,
                                    targetID: target, split: .down) {
                                    worktree.wrappedValue.workspaceLayout?.addTerminal(slot)
                                }
                            } else {
                                _ = PaneCommands.startWorktree(path: worktree.wrappedValue.path, appState: $appState,
                                    terminalManager: terminalManager)
                                if let slot = worktree.wrappedValue.splitTree.allLeaves.first {
                                    worktree.wrappedValue.workspaceLayout?.addTerminal(slot)
                                }
                            }
                        },
                        onCloseTerminal: { slot in
                            PaneCommands.closePane(appState: $appState, terminalManager: terminalManager,
                                targetID: slot, userInitiated: true)
                        },
                        agentScrollbackMap: agentScrollbackMap
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
            } inspector: {
                if showsWorktreeContext, let context = selectedContext {
                    WorktreeContextPanel(context: context, theme: terminalManager.theme.core,
                        readTranscript: transcriptReader, showAgent: agentTabOpener, onClose: { showsWorktreeContext = false })
                        .environment(\.worktreeContextActions, WorktreeContextActions(openWorktree: { [identity = selectedRemoteIdentity] path, _ in
                            openContextWorktree(path, remoteIdentity: identity)
                        }, revealInTerminal: { [identity = selectedRemoteIdentity] request in
                            await revealInTerminal(request, remoteIdentity: identity)
                        }))
                        .frame(width: 360)
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
        .sheet(isPresented: $isShowingLinuxHostSetupSheet) {
            if let linuxHostSetupClient {
                LinuxHostSetupSheet(
                    client: linuxHostSetupClient,
                    initialProjects: appState.repos.filter(\.isGitTracked).map { repo in
                        LinuxHostProject(
                            localPath: repo.path,
                            branch: repo.worktrees.first { $0.path == repo.path }?.branch ?? repo.defaultBranchHint ?? "",
                            directoryName: URL(fileURLWithPath: repo.path).lastPathComponent
                        )
                    },
                    onConnect: completeLinuxHostSetup
                )
            }
        }
        .sheet(item: $pendingHostMaintenance) { request in
            LinuxHostMaintenanceSheet(remote: request.remote, pinnedHost: request.pinnedHost,
                onValidated: { destination in
                    try remoteMacsModel.saveMaintenanceDestination(destination, for: RemoteMacIdentity(request.remote))
                }, onReconnect: {
                    do { try await remoteMacsModel.reconnectAfterMaintenance(request.remote); return true }
                    catch { return false }
                })
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
        .focusedSceneValue(\.addWorktreeAction, addWorktreeAction)
        .focusedSceneValue(\.addRepositoryAction, addRepository)
        .focusedSceneValue(\.worktreeNavAction, worktreeNavAction)
        .persistSidebarWidth(to: Binding(
            get: { appState.sidebarWidth },
            set: { appState.sidebarWidth = $0 }
        ), when: true)
        .onChange(of: selectedVoicePaneID) { _, _ in
            voiceDictation.cancel()
        }
        .onChange(of: previewWindows.inlineTarget) { _, target in
            guard let target,
                  let indices = appState.indicesOfWorktreeContaining(terminalID: target.pane),
                  appState.repos[indices.repo].worktrees[indices.worktree].path == target.worktreePath else { return }
            let tree = appState.repos[indices.repo].worktrees[indices.worktree].splitTree
            if let zoomed = tree.zoomed, zoomed != target.pane {
                appState.repos[indices.repo].worktrees[indices.worktree].splitTree = tree.withZoom(nil)
            }
            selectPane(target.worktreePath, target.pane)
            makePaneFirstResponder(target.pane, when: {
                selectedRemoteIdentity == nil && appState.selectedWorktreePath == target.worktreePath
                    && appState.worktree(forPath: target.worktreePath)?.focusedPaneSlotID == target.pane
            }, onFocused: {
                terminalManager.view(for: target.pane)?.window?.makeKeyAndOrderFront(nil)
            })
        }
        .onChange(of: currentNavigationTarget, initial: true) { _, target in
            worktreeHistory.record(target)
        }
        .onChange(of: appState.selectedWorktreePath, initial: true) { oldPath, newPath in
            guard let newPath else { return }
            terminalManager.surfaceBudget.noteSelected(
                worktreePath: newPath,
                splitTreesByPath: appState.runningSplitTreesByPath()
            )
        }
        .onChange(of: remoteMacsModel.worktreePanesByRemote) { _, snapshots in
            remoteViewer.reconcile(worktreePanesByRemote: snapshots)
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
        .modifier(AgentNotificationActivationHandler(
            activation: .shared, onActivate: activateLocalNotification))
        .onDisappear {
            voiceDictation.cancel()
            remoteViewer.destroyAllRemoteSurfaces()
        }
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

    private var selectedIdentityProject: SidebarProject? {
        if let remote = selectedRemoteWorktreeSnapshot {
            let id = SidebarProjection.projectID(remote)
            return appState.sidebarNavigation?.cachedProjects.first { $0.id == id }
                ?? SidebarProjection.projects([remote]).first
        }
        return selectedRepo.map { iconStore.project(for: $0, owner: iconStore.owner) }
    }

    private var selectedProjectIconData: Data? {
        if selectedRemoteWorktreeSnapshot != nil {
            return selectedIdentityProject.flatMap { iconStore.remoteIcons[$0.id] }
        }
        return selectedRepo.flatMap { iconStore.iconData(for: $0) }
    }

    private var selectedRepo: RepoEntry? {
        guard let path = appState.selectedWorktreePath else { return nil }
        return appState.repo(forWorktreePath: path)
    }

    private var currentNavigationTarget: WorktreeNavigationTarget? {
        if let identity = selectedRemoteIdentity {
            return selectedRemoteWorktreePath.map { .remote(identity, $0) }
        }
        return appState.selectedWorktreePath.map { .local($0) }
    }

    private var agentTabOpener: ((String) -> Void)? {
        if selectedRemoteIdentity != nil { return { requestedRemoteAgent = $0 } }
        guard let worktree = selectedWorktreeBinding else { return nil }
        return { id in
            guard let slot = worktree.wrappedValue.showAgentTab(id) else { return }
            if worktree.wrappedValue.hasCompletedContent(in: slot) { terminalManager.clearFocus() }
            else { terminalManager.setFocus(slot) }
        }
    }

    private var transcriptReader: (@MainActor (String) async -> String?)? {
        guard selectedRemoteIdentity == nil else { return nil }
        return { id in await readAgentTranscript(id) }
    }

    private func readAgentTranscript(_ id: String) async -> String? {
        guard let agent = selectedWorktree?.agents.first(where: { $0.id == id }) else { return nil }
        do { return try await OffMainIO.run { try AgentArchiveStore().preview(agent) } }
        catch { return "Could not read transcript: " + error.localizedDescription }
    }

    private func historyItem(_ target: WorktreeNavigationTarget) -> BreadcrumbHistoryItem? {
        switch target {
        case .local(let path):
            guard let worktree = appState.worktree(forPath: path),
                  worktree.state.hasOnDiskWorktree,
                  let repo = appState.repo(forWorktreePath: path) else { return nil }
            let name = SidebarWorktreeLabel.text(
                for: worktree, inRepoAtPath: repo.path,
                siblingPaths: repo.worktrees.map(\.path),
                defaultBranch: remoteBranchStore.resolvedDefaultBranch(forRepoAt: repo.path, hint: repo.defaultBranchHint)
            )
            return BreadcrumbHistoryItem(target: target, repoName: repo.displayName,
                worktreeName: name, branchName: worktree.displayBranch, remoteMacName: nil)
        case .remote(let identity, let path):
            guard remoteMacsModel.connectionState(for: identity) == .connected,
                  let mac = remoteMacsModel.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == identity }),
                  let worktree = remoteMacsModel.worktreePanesByRemote[identity]?.first(where: {
                      $0.path == path && ($0.origin?.relayDepth ?? 0) == 0
                  }), worktree.state.hasOnDiskWorktree else { return nil }
            return BreadcrumbHistoryItem(target: target, repoName: worktree.repoDisplayName,
                worktreeName: worktree.displayName, branchName: worktree.displayBranch, remoteMacName: mac.label)
        }
    }

    private func isHistoryTargetAvailable(_ target: WorktreeNavigationTarget) -> Bool {
        historyItem(target) != nil
    }

    private func navigateWorktreeHistory(forward: Bool) {
        worktreeHistory.record(currentNavigationTarget)
        guard let target = worktreeHistory.navigate(forward: forward, isAvailable: isHistoryTargetAvailable) else { return }
        selectHistoryTarget(target)
    }

    private func selectHistoryTarget(_ target: WorktreeNavigationTarget) {
        guard isHistoryTargetAvailable(target) else { return }
        switch target {
        case .local(let path):
            selectWorktree(path)
        case .remote(let identity, let path):
            guard let mac = remoteMacsModel.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == identity }) else { return }
            selectRemoteWorktree(mac, worktreePath: path)
        }
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

    private var selectedRemoteIdentity: RemoteMacIdentity? { remoteViewer.selectedRemoteIdentity }
    private var selectedRemoteWorktreePath: String? { remoteViewer.selectedRemoteWorktreePath }
    private var selectedRemotePaneSessionName: String? { remoteViewer.selectedRemotePaneSessionName }
    private var selectedRemoteMac: RemoteMac? { remoteViewer.selectedRemoteMac }
    private var selectedRemoteWorktreeSnapshot: WorktreePanes? { remoteViewer.selectedWorktreeSnapshot }
    private var focusedRemoteTerminalID: PaneSlotID? { remoteViewer.focusedTerminalID }

    private func openContextWorktree(_ path: String, remoteIdentity: RemoteMacIdentity?) -> Bool {
        if let remoteIdentity {
            guard let mac = remoteMacsModel.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == remoteIdentity }),
                  remoteMacsModel.connectionState(for: remoteIdentity) == .connected,
                  let row = remoteMacsModel.worktreePanesByRemote[remoteIdentity]?.first(where: {
                      $0.path == path && ($0.origin?.relayDepth ?? 0) == 0
                  }), row.state.hasOnDiskWorktree, !row.state.isInFlight else { return false }
            selectRemoteWorktree(mac, worktreePath: path)
            return true
        }
        guard let worktree = appState.worktree(forPath: path), worktree.state.hasOnDiskWorktree,
              !worktree.state.isInFlight else { return false }
        attentionOpenGeneration &+= 1
        return selectWorktree(path, acknowledging: true)
    }

    /// Scrolls the context worktree's agent pane, local or remote, to a timeline message.
    private func revealInTerminal(_ request: TerminalRevealRequest, remoteIdentity: RemoteMacIdentity?) async -> Bool {
        let handle: SurfaceHandle?
        if let remoteIdentity {
            handle = remoteViewer.existingTerminalID(identity: remoteIdentity, worktreePath: request.worktree.path,
                                                     sessionName: request.paneID).flatMap { terminalManager.handle(for: $0) }
        } else {
            handle = terminalManager.handle(forSessionName: request.paneID)
        }
        guard let handle else { return false }
        return await handle.reveal(eventID: request.eventID, messages: request.messages)
    }

    /// The selected worktree's agent pane, local or remote, and the timeline its scrollback map marks.
    private var agentScrollbackMap: AgentScrollbackMap? {
        guard let context = selectedContext, let session = context.agentPaneID else { return nil }
        let terminalID: PaneSlotID?
        if let remoteIdentity = selectedRemoteIdentity {
            terminalID = remoteViewer.existingTerminalID(identity: remoteIdentity, worktreePath: context.worktree.path,
                                                         sessionName: session)
        } else {
            terminalID = terminalManager.handle(forSessionName: session)?.terminalID
        }
        return terminalID.map { AgentScrollbackMap(terminalID: $0, timeline: WorktreeTimeline(context)) }
    }

    private var selectedContext: SidebarWorktreeContext? {
        if let remote = selectedRemoteWorktreeSnapshot { return sidebarNavigation.worktreeContext(remote) }
        guard selectedRemoteIdentity == nil, let path = selectedWorktree?.path else { return nil }
        return sidebarLocalWorktree(atPath: path, state: appState, owner: iconStore.owner, titles: terminalManager.displayTitles,
            liveness: claudeSessionRegistry.livenessBySession, prBadge: prStatusStore.infos[path].map { PRBadge(from: $0) },
            defaultBranch: { remoteBranchStore.resolvedDefaultBranch(forRepoAt: $0.path, hint: $0.defaultBranchHint) })
            .map { sidebarNavigation.worktreeContext($0) }
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
    private func openAttentionTarget(_ item: SidebarActivityItem) async -> Bool {
        attentionOpenGeneration &+= 1
        let generation = attentionOpenGeneration
        if let route = remoteMacsModel.relayRouter.resolveWorktree(item.worktreeID),
           let mac = remoteMacsModel.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == route.identity }) {
            guard let worktree = remoteMacsModel.worktreePanesByRemote[route.identity]?.first(where: { $0.path == route.path }),
                  worktree.state.hasOnDiskWorktree else { return false }
            if worktree.state == .closed {
                guard await remoteMacsModel.openWorktree(on: mac, worktreePath: route.path) == .ok else { return false }
                for _ in 0..<20 {
                    guard !Task.isCancelled, generation == attentionOpenGeneration else { return false }
                    if remoteMacsModel.worktreePanesByRemote[route.identity]?.first(where: { $0.path == route.path })?.layout != nil { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            guard generation == attentionOpenGeneration,
                  remoteMacsModel.worktreePanesByRemote[route.identity]?.first(where: { $0.path == route.path })?.layout != nil else { return false }
            guard let current = remoteMacsModel.promotedWorktreesForRelay().first(where: { $0.path == item.worktreeID }) else { return false }
            var resolvedItem = item
            if let paneID = SidebarProjection.attentionPaneRoute(for: item, in: current) {
                guard let pane = remoteMacsModel.relayRouter.resolvePane(paneID) else { return false }
                if item.paneID != nil { resolvedItem.paneID = paneID }
                selectRemotePane(mac, worktreePath: route.path, sessionName: pane.sessionName, acknowledging: false)
            } else {
                guard item.paneID == nil else { return false }
                selectRemoteWorktree(mac, worktreePath: route.path, acknowledging: false)
            }
            let supportsExact = await remoteMacsModel.sidebarSnapshot(for: mac)?.projects
                .first(where: { $0.id == item.projectID })?.supportsWorktreeEditing == true
            if let request = SidebarInteractionPolicy.acknowledgementOnOpen(for: resolvedItem, supportsExactAcknowledgement: supportsExact) {
                guard let response = await remoteMacsModel.sendRelayedWorktreeManagement(request) else { return false }
                if case .error(let code, _, _, _) = response, code != "occurrence-changed" { return false }
            }
            return true
        }
        guard let worktree = appState.worktree(forPath: item.worktreeID), worktree.state.hasOnDiskWorktree else { return false }
        var selectedSlot: PaneSlotID?
        let metadata = SidebarHostNavigation.metadata(for: worktree, projectID: item.projectID, folders: [])
        if item.paneID != nil {
            guard let slotID = SidebarProjection.paneSlotID(for: item, in: metadata),
                  let slot = worktree.splitTree.allLeaves.first(where: { $0.id.uuidString == slotID }) else { return false }
            selectedSlot = slot
        } else if let slotID = item.agentStop?.paneSlotID {
            selectedSlot = worktree.splitTree.allLeaves.first { $0.id.uuidString == slotID }
        } else if let title = item.agentStop?.paneTitle {
            let matches = worktree.splitTree.allLeaves.filter { terminalManager.displayTitles[$0] == title }
            if matches.count == 1 { selectedSlot = matches[0] }
        } else if worktree.splitTree.allLeaves.count == 1 { selectedSlot = worktree.splitTree.allLeaves.first }
        if let selectedSlot { selectPane(worktree.path, selectedSlot, acknowledging: false) }
        else { selectWorktree(worktree.path, acknowledging: false) }
        guard appState.selectedWorktreePath == item.worktreeID,
              let active = appState.worktree(forPath: item.worktreeID), active.state == .running,
              !active.splitTree.allLeaves.isEmpty else { return false }
        if let occurrence = item.occurrence, occurrence.source != .agentStop {
            let paneID = item.paneID == nil ? nil : selectedSlot.flatMap { active.paneSessions[$0] }.map { ZmxLauncher.sessionName(for: $0) }
            SidebarHostNavigation.acknowledge(in: &appState, worktreeID: item.worktreeID, paneID: paneID, occurrence: occurrence)
        }
        return true
    }

    private func selectPane(_ worktreePath: String, _ terminalID: PaneSlotID) {
        attentionOpenGeneration &+= 1
        selectPane(worktreePath, terminalID, acknowledging: true)
    }

    @discardableResult
    private func selectPane(_ worktreePath: String, _ terminalID: PaneSlotID, acknowledging: Bool) -> Bool {
        guard selectWorktree(worktreePath, acknowledging: acknowledging) else { return false }
        appState.mutateWorktrees(atPath: worktreePath) { $0.focusedPaneSlotID = terminalID }
        terminalManager.setFocus(terminalID)
        makePaneFirstResponder(
            terminalID,
            when: {
                appState.selectedWorktreePath == worktreePath
                    && appState.worktree(forPath: worktreePath)?.firstPane
                        == terminalID
            }
        )
        return true
    }

    private func selectWorktree(_ path: String) {
        attentionOpenGeneration &+= 1
        selectWorktree(path, acknowledging: true)
    }

    @discardableResult
    private func selectWorktree(_ path: String, acknowledging: Bool, inspectingCreation: Bool = true) -> Bool {
        if inspectingCreation, let worktree = appState.worktree(forPath: path), worktree.showsCreationProgress {
            if let previous = appState.selectedWorktreePath, previous != path {
                setWorktreeSurfacesVisible(false, worktreePath: previous)
            }
            remoteViewer.leaveForLocalSelection()
            appState.selectedWorktreePath = path
            return true
        }
        guard appState.worktree(forPath: path)?.state.isInFlight != true,
              terminalManager.wakeWorktree(path) else { return false }
        remoteViewer.leaveForLocalSelection()
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
        // transition, so the resurrected worktree has no path / head
        // watchers. Re-arm now so real-time stats and PR
        // refreshes work without waiting for the next `.git/worktrees/`
        // FSEvents tick (which a user-click resurrection never fires).
        if let repoPath = resurrectedRepoPath {
            worktreeMonitor.watchWorktreePath(path)
            worktreeMonitor.watchHeadRef(worktreePath: path, repoPath: repoPath)
        }

        for repoIdx in appState.repos.indices {
            for wtIdx in appState.repos[repoIdx].worktrees.indices {
                if appState.repos[repoIdx].worktrees[wtIdx].path != path {
                    continue
                }

                if appState.repos[repoIdx].worktrees[wtIdx].state == .closed,
                   !appState.repos[repoIdx].worktrees[wtIdx].agents.contains(where: { $0.completion != nil }) {
                    _ = PaneCommands.startWorktree(
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

        // STATE-2.4: viewing clears notifications at both scopes while
        // preserving stopped-agent requests.
        if acknowledging {
            appState.mutateWorktrees(atPath: path) { $0.viewAttention() }
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
           let target = wt.presentationPane, wt.hasCompletedContent(in: target) {
            terminalManager.clearFocus()
        } else if let wt = appState.worktree(forPath: path), let target = wt.presentationPane {
            makePaneFirstResponder(
                target,
                when: {
                    appState.selectedWorktreePath == path
                        && appState.worktree(forPath: path)?.presentationPane == target
                }
            )
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
        return true
    }

    private func activateLocalNotification(_ payload: AgentStopNotificationPayload) {
        attentionOpenGeneration &+= 1
        pendingRemoteNotificationActivation = nil
        AgentNotificationActivation.open(payload, worktree: appState.worktree(forPath: payload.worktreePath),
            selectWorktree: { selectWorktree($0, acknowledging: true) },
            selectPane: { selectPane($0, $1, acknowledging: true) })
    }

    @MainActor
    private func presentLinuxHostSetup() {
        do {
            let store = ClientIdentityStore(directory: ClientIdentityStore.defaultDirectory)
            let key = try store.loadOrGenerateAndPersist()
            linuxHostSetupClient = LinuxHostTrustRequest(
                deviceID: try AppServices.localRemoteDeviceID().value,
                displayName: AppServices.localHostDisplayName(),
                publicKey: key.publicKey.rawRepresentation.base64EncodedString()
            )
            isShowingLinuxHostSetupSheet = true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not prepare Linux host setup"
            alert.informativeText = LinuxHostSetupError.message(for: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @MainActor
    private func completeLinuxHostSetup(_ result: LinuxHostSetupResult) async throws {
        try Task.checkCancellation()
        await remoteMacsModel.loadSavedRemotes()
        try Task.checkCancellation()
        let controller = LinuxHostSetupConnectionController(
            pinnedHostStore: PinnedHostStore(directory: PinnedHostStore.defaultDirectory)
        )
        let saved = try controller.save(result, model: remoteMacsModel)
        do {
            _ = try await remoteMacsModel.connect(to: saved)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw LinuxHostSetupError.invalidPlan("The host is installed and paired, but Graftty could not reach \(saved.directEndpoint?.host ?? result.openSSH.hostname):\(result.identity.port). Check the firewall and direct network route, then retry.\n\(error.localizedDescription)")
        }
    }

    private func selectRemoteMac(_ remoteMac: RemoteMac) {
        attentionOpenGeneration &+= 1
        leaveLocalSelectionForRemote()
        remoteViewer.selectRemoteMac(remoteMac)

        Task { @MainActor in
            do {
                _ = try await remoteMacsModel.connectFromUserSelection(
                    to: remoteMac
                )
                _ = try await remoteMacsModel.refreshRepositories(
                    on: remoteMac
                )
            } catch {
                NSLog("[Graftty] failed to connect remote Mac %@: %@", remoteMac.label, String(describing: error))
            }
        }
    }

    private func selectRemoteWorktree(_ remoteMac: RemoteMac, worktreePath: String) {
        attentionOpenGeneration &+= 1
        selectRemoteWorktree(remoteMac, worktreePath: worktreePath, acknowledging: true)
    }

    private func selectRemoteWorktree(_ remoteMac: RemoteMac, worktreePath: String, acknowledging: Bool) {
        guard remoteViewer.canSelectRemoteWorktree(remoteMac, worktreePath: worktreePath) else { return }
        leaveLocalSelectionForRemote()
        remoteViewer.selectRemoteWorktree(remoteMac, worktreePath: worktreePath, acknowledging: acknowledging)
    }

    /// Selecting anything remote hides the local worktree's surfaces and
    /// clears the local half of the sidebar selection.
    private func leaveLocalSelectionForRemote() {
        if let localPath = appState.selectedWorktreePath {
            setWorktreeSurfacesVisible(false, worktreePath: localPath)
        }
        appState.selectedWorktreePath = nil
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
        RemoteWorktreeViewerController.presentAlert(message)
    }

    private func selectRemotePane(_ remoteMac: RemoteMac, worktreePath: String, sessionName: String) {
        attentionOpenGeneration &+= 1
        selectRemotePane(remoteMac, worktreePath: worktreePath, sessionName: sessionName, acknowledging: true)
    }

    private func selectRemotePane(_ remoteMac: RemoteMac, worktreePath: String, sessionName: String, acknowledging: Bool) {
        leaveLocalSelectionForRemote()
        remoteViewer.selectRemotePane(
            remoteMac,
            worktreePath: worktreePath,
            sessionName: sessionName,
            acknowledging: acknowledging
        )
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

    private var selectedVoicePaneID: PaneSlotID? {
        selectedRemoteIdentity == nil ? selectedWorktree?.focusedPaneSlotID : focusedRemoteTerminalID
    }

    private func setWorktreeSurfacesVisible(_ visible: Bool, worktreePath: String) {
        guard let wt = appState.worktree(forPath: worktreePath), wt.state == .running else { return }
        let visibleSlots = wt.visiblePaneSlots
        for terminalID in wt.splitTree.allLeaves {
            terminalManager.setVisible(visible && visibleSlots.contains(terminalID), for: terminalID)
        }
    }

    private func applyAppVisibility(isVisible: Bool) {
        if remoteViewer.setAppVisible(isVisible) { return }
        guard let action = AppVisibilitySurfacePolicy.action(
            selectedWorktreePath: appState.selectedWorktreePath,
            appIsVisible: isVisible
        ) else { return }
        switch action {
        case let .setSelectedWorktreeVisible(path, visible):
            setWorktreeSurfacesVisible(visible, worktreePath: path)
        }
    }

    private func makePaneFirstResponder(
        _ terminalID: PaneSlotID,
        when shouldFocus: (() -> Bool)? = nil,
        onFocused: (() -> Void)? = nil
    ) {
        terminalManager.promoteToFirstResponder(terminalID, when: shouldFocus, onFocused: onFocused)
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
                terminalStartTiming: AddWorktreeFlow.terminalStartTiming(for: .nativeSidebar)
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
    private func deleteWorktreeWithConfirmation(_ worktreePath: String, on host: NSWindow) {
        DeleteWorktreeConfirmation.present(worktreePath: worktreePath, on: host) { path, window in
            performDeleteWorktree(path, on: window)
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

    /// Runs `git worktree remove` and tears down the worktree after
    /// the caller confirms deletion. Surfaces failures via an error
    /// alert. `force` is set internally on retry from
    /// the GIT-4.4 dialog; see GIT-4.12.
    private func performDeleteWorktree(_ worktreePath: String, on host: NSWindow, force: Bool = false) {
        Task { @MainActor [weak host] in
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
                guard let host, host.isVisible else { return }
                let config = ForceDeleteAlert.gitFailedForceableConfiguration(stderr: stderr, status: status)
                SheetAlert.present(config, on: host) { response in
                    guard response == .secondary else { return }
                    performDeleteWorktree(worktreePath, on: host, force: true)
                }
            case .failure(.gitFailedFinal(let msg)):
                NSLog("[Graftty] performDeleteWorktree: %@", msg)
                guard let host, host.isVisible else { return }
                let config = ForceDeleteAlert.gitFailedFinalConfiguration(message: msg)
                SheetAlert.present(config, on: host)
            }
        }
    }

    private func movePane(_ terminalID: PaneSlotID, to newPWD: String) {
        PaneCommands.reassignPaneByPWD(
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
            let registration: ProjectRegistration
            do {
                registration = try await ProjectRegistration.prepare(path: selectWorktree ?? repoPath)
            } catch {
                NSLog("[Graftty] addRepoFromPath: discover failed for %@: %@", repoPath, String(describing: error))
                let alert = NSAlert()
                alert.messageText = "Could not add repository"
                alert.informativeText = "\(repoPath)\n\n\(String(describing: error))"
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            registration.apply(to: &appState)
            if let repo = appState.repos.first(where: { $0.path == registration.repo.path }) {
                worktreeMonitor.installRepoWatchers(repo: repo)
            }
            remoteBranchStore.refresh(repoPath: registration.repo.path)
            self.selectWorktree(registration.selectedWorktreePath)

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
