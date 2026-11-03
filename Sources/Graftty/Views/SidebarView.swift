import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

private struct SidebarAddWorktreeButtonAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct SleepingWorktreeIndicator: View {
    @ObservedObject var state: WorktreeSleepState
    let path: String

    var body: some View {
        if state.paths.contains(path) {
            Image(systemName: "moon.zzz.fill")
                .font(.caption).foregroundStyle(.secondary)
                .help("Sleeping. Open to resume existing sessions.")
                .accessibilityLabel("Sleeping worktree")
                .padding(.trailing, 6)
        }
    }
}

/// @spec LAYOUT-2.62: When the project rail setting changes, the application shall place Add Repository beside Manage Remote Hosts in the project footer if enabled, or retain the labeled Add Repository button in the single-sidebar footer if disabled.

/// @spec LAYOUT-2.64: When the pointer rests over a repository or remote Mac footer icon, the application shall display a tooltip describing the button's action.
struct SidebarView: View {
    @Binding var appState: AppState
    /// Used to read pane titles. Title change invalidation is deliberately
    /// scoped to `paneTitleInvalidations` below so MainWindow does not
    /// recompute on every shell title/PWD event.
    let terminalManager: TerminalManager
    @ObservedObject var paneTitleInvalidations: PaneTitleInvalidationSource
    @ObservedObject var voiceDictation: VoiceDictationController
    let selectedVoicePaneID: PaneSlotID?
    let theme: GhosttyTheme
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    /// Injected by GrafttyApp so each pane row can merge derived claude
    /// busy/idle liveness (notify pings still win) into its attention pill.
    let claudeSessionRegistry: ClaudeSessionRegistry
    let remoteBranchStore: RemoteBranchStore
    @ObservedObject var remoteMacsModel: RemoteMacsModel
    var remoteWorkspaceLayout: (RemoteMacIdentity, WorktreePanes) -> WorkspaceLayout<String> = { _, row in .initial(for: row) }
    let appStateChanges: AppStateChanges
    let selectedRemoteIdentity: RemoteMacIdentity?
    let selectedRemoteWorktreePath: String?
    let selectedRemotePaneSessionName: String?
    let onSelect: (String) -> Void
    var onOpenAttention: (SidebarActivityItem) async -> Bool = { _ in false }
    var onNavigationIntent: () -> Void = {}
    let onSelectPane: (String, PaneSlotID) -> Void
    let onSelectRemoteMac: (RemoteMac) -> Void
    let onSelectRemoteWorktree: (RemoteMac, String) -> Void
    let onSelectRemotePane: (RemoteMac, String, String) -> Void
    let onAddRemoteWorktree: (RemoteMac, RemoteRepositoryInfo) -> Void
    let onDeleteRemoteWorktree: (RemoteMac, WorktreePanes) -> Void
    let onAddRemoteMac: () -> Void
    var onSetupLinuxHost: (() -> Void)? = nil
    var onUpdateHost: ((RemoteMac) -> Void)? = nil
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onRemoveRepo: (RepoEntry) -> Void
    let onInitializeGit: (RepoEntry) -> Void
    let onStopWorktree: (String) -> Void
    let onDeleteWorktree: (String, NSWindow) -> Void
    /// Called when the user submits the add-worktree sheet. Returns nil
    /// on success, or a user-visible error string (typically git's
    /// stderr) on failure so the sheet can display it inline.
    let onAddWorktree: (RepoEntry, String, BranchSelection, WorktreeAgentConfiguration) async -> String?

    /// Injected by GrafttyApp so the pane-row context menu can gate the
    /// "Copy web URL" item on `controller.status == .listening` and read
    /// the listening addresses to compose the URL.
    @EnvironmentObject private var webController: WebServerController

    /// Injected by GrafttyApp so each pane row can render port-binding
    /// chips for ports its process subtree is currently listening on.
    @EnvironmentObject private var portBindings: PortBindingsModel

    /// SwiftUI's environment-provided window-opener. Used by the
    /// worktree-row context menu's *Show Team Activity…* item
    /// (TEAM-7.2) to route to the `TeamActivityLogWindowID`-keyed
    /// `WindowGroup` declared in `GrafttyApp`.
    @Environment(\.openWindow) private var openWindow

    @Binding var pendingAddWorktree: AddWorktreeRequest?

    @State private var remoteSectionExpansion = RemoteSidebarExpansion()

    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    @State var navigation = SidebarNavigationState(prefix: "sidebar.mac")
    @StateObject private var reportController = SidebarReportController()
    @State private var frozenWorktreeOrder: [UUID: [UUID]] = [:]
    @State private var frozenPins: [UUID: Bool] = [:]
    @State private var frozenRemoteRows: [RemoteMacIdentity: [WorktreePanes]] = [:]
    @State private var frozenMergedOrder: [String: [String]] = [:]
    /// The row last selected in each merged project. Paths alone can repeat across hosts.
    @State private var rememberedRowIDs: [String: String] = [:]
    @State private var collapsedMergedFolders: Set<String> = []
    @ObservedObject private var iconStore = SidebarHostController.shared
    @State private var projects: [SidebarProject] = []
    @State private var navigationError: String?
    @State private var remoteProjectOperationInProgress = false
    @State private var showsRemoteManagement = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var owner: WorktreeOrigin { iconStore.owner }
    private func localProjectID(_ repo: RepoEntry) -> String { "\(owner.deviceID.value):\(repo.id.uuidString)" }
    private var localWorktrees: [WorktreePanes] {
        sidebarLocalWorktrees(state: appState, owner: owner, titles: terminalManager.displayTitles,
            liveness: claudeSessionRegistry.livenessBySession, prBadges: prStatusStore.infos.mapValues { PRBadge(from: $0) },
            defaultBranch: { remoteBranchStore.resolvedDefaultBranch(forRepoAt: $0.path, hint: $0.defaultBranchHint) })
    }
    private func activityCounts(_ rows: [WorktreePanes]) -> SidebarActivityCounts {
        let pending = rows.flatMap { navigation.worktreeContext($0).pending }
        let working = SidebarProjection.activity(rows).filter(\.isBusy).map { item in
            var item = item
            item.occurrence = nil
            return item
        }
        return SidebarActivityCounts(items: pending + working)
    }

    private func pinnedMembership(in rows: [WorktreePanes], merged: SidebarMergedRows) -> Set<String> {
        let projectFilter = SidebarLayoutPolicy.projectFilter(selectedID: merged.selectedProjectID(for: navigation.selectedProjectID), showsProjectRail: showsProjectRail)
        return Set(rows.filter {
            (projectFilter == nil || merged.mergedID(forMember: SidebarProjection.projectID($0)) == projectFilter)
                && ($0.isMainCheckout || $0.sidebar?.isPinned == true)
        }.map { SidebarProjection.projectID($0) + "\u{0}" + $0.path })
    }

    private func contextForLocalWorktree(_ worktree: WorktreeEntry, repo: RepoEntry, displayName: String) -> SidebarWorktreeContext {
        navigation.worktreeContext(sidebarLocalWorktree(worktree, repo: repo, owner: owner,
            displayName: displayName, titles: terminalManager.displayTitles,
            liveness: claudeSessionRegistry.livenessBySession,
            prBadge: prStatusStore.infos[worktree.path].map { PRBadge(from: $0) },
            ports: worktree.state == .running ? portBindings.ports(for: worktree.splitTree.allLeaves) : []))
    }

    private func displayedWorktrees(in repo: RepoEntry) -> [WorktreeEntry] {
        let live = SidebarHostNavigation.displayedWorktrees(in: repo)
        guard let order = frozenWorktreeOrder[repo.id] else { return live }
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return live.enumerated().sorted {
            positions[$0.element.id, default: order.count + $0.offset] < positions[$1.element.id, default: order.count + $1.offset]
        }.map { entry in
            var row = entry.element
            row.isPinned = frozenPins[row.id] ?? row.isPinned
            return row
        }
    }

    /// Every project and row once, from all hosts. Compute once per use: it
    /// projects every worktree.
    private var mergedSidebar: SidebarMergedRows {
        SidebarMergedRows.make(projects: projects, localRows: localWorktrees,
            remoteRows: displayedRemoteRows.values.flatMap { $0 }, localDeviceID: owner.deviceID,
            availability: { $0.isAvailable ? .reachable : .offline })
    }

    private var displayedRemoteRows: [RemoteMacIdentity: [WorktreePanes]] {
        Dictionary(uniqueKeysWithValues: remoteMacsModel.worktreePanesByRemote.map { identity, live in
            guard let frozen = frozenRemoteRows[identity] else { return (identity, live) }
            let rows = SidebarWorktreeReportOrder(worktrees: frozen).orderedWorktrees(live)
            return (identity, rows)
        })
    }

    private func openReport(_ context: SidebarWorktreeContext) async -> Bool {
        let item = context.pending.first ?? context.item
        guard projects.first(where: { $0.id == item.projectID })?.isAvailable == true else { return false }
        onNavigationIntent()
        let visit = navigation.beginOpening(item)
        let opened = await onOpenAttention(item)
        navigation.finishOpening(visit, succeeded: opened, navigateToProject: opened)
        if !opened { navigationError = "This target is unavailable or its request has changed." }
        return opened
    }

    private var projectIcons: [String: Data] {
        var result = iconStore.remoteIcons
        for repo in appState.repos { result[localProjectID(repo)] = iconStore.iconData(for: repo) }
        return result
    }
    private func refreshNavigation() async {
        await iconStore.refreshOriginKeys(state: $appState)
        let remote = await remoteMacsModel.sidebarRelaySnapshot()
        let snapshot = iconStore.snapshot(state: $appState, owner: owner, remote: remote.projects,
            authoritativeRemoteOwners: remote.authoritativeOwnerIDs, savedRemoteOwners: Set(remoteMacsModel.savedRemoteMacs.map(\.id)))
        if projects != snapshot.projects { projects = snapshot.projects }
        let authoritativeProjects = Set(appState.repos.map(localProjectID))
            .union(remote.projects.filter {
                $0.owner.map { remote.authoritativeOwnerIDs.contains($0.deviceID) } == true
            }.map(\.id))
        navigation.reconcile(worktrees: localWorktrees + remote.worktrees, projects: projects,
            authoritativeProjectIDs: authoritativeProjects)
        // Store the merged id, so the selection outlives whichever host set it.
        let merged = mergedSidebar
        let selected = merged.selectedProjectID(for: navigation.selectedProjectID)
        let fallback = appState.repos.first(where: { repo in repo.worktrees.contains { $0.path == appState.selectedWorktreePath } })
            .map { merged.mergedID(forMember: localProjectID($0)) } ?? merged.projects.first?.id
        let next = selected ?? fallback
        if navigation.selectedProjectID != next { navigation.selectedProjectID = next }
        iconStore.remoteIconCache.reconcile(remote.projects)
        for project in remote.projects where project.isAvailable {
            guard let revision = project.iconRevision else { continue }
            await iconStore.remoteIconCache.load(for: project) {
                if case .icon(let data) = await remoteMacsModel.sendRelayedWorktreeManagement(
                    .projectIcon(repositoryID: project.repositoryID, revision: revision)) { return data }
                return nil
            }
        }
    }
    private func rememberSelection(_ path: String?) {
        guard let path, let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == path } }),
              let row = localWorktrees.first(where: { $0.path == path }) else { return }
        remember(row, projectID: localProjectID(repo))
    }
    private func remember(_ row: WorktreePanes, projectID: String) {
        let mergedID = mergedSidebar.mergedID(forMember: projectID)
        navigation.rememberedWorktrees[mergedID] = row.path
        rememberedRowIDs[mergedID] = MergedWorktreeList.identity(row)
    }
    private func rememberRemoteSelection() {
        guard let identity = selectedRemoteIdentity, let path = selectedRemoteWorktreePath,
              let row = remoteMacsModel.worktreePanesByRemote[identity]?.first(where: { $0.path == path }) else { return }
        remember(row, projectID: SidebarProjection.projectID(row))
    }
    private func selectProject(_ project: SidebarProject) {
        onNavigationIntent()
        rememberSelection(appState.selectedWorktreePath)
        rememberRemoteSelection()
        let merged = mergedSidebar
        navigation.showProject(project.id); navigationError = nil
        guard project.isAvailable else { navigationError = "The owning host is offline. Use Manage Remote Hosts to reconnect."; return }
        let rows = merged.flattenedRows(for: project.id)
        guard let target = rows.first(where: { $0.id == rememberedRowIDs[project.id] }) ?? rows.first else { return }
        openMergedRow(target)
    }
    private func openMergedRow(_ row: MergedWorktreeRow) {
        if row.hostID == owner.deviceID {
            if let index = appState.repos.firstIndex(where: { $0.worktrees.contains { $0.path == row.row.path } }) {
                appState.repos[index].isCollapsed = false
            }
            onSelect(row.row.path)
        } else if let mac = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == row.hostID }) {
            onSelectRemoteWorktree(mac, row.row.path)
        }
    }
    private func moveProject(_ id: String, _ target: String, _ after: Bool) {
        guard var state = appState.sidebarNavigation else { return }
        guard state.order.move(id, relativeTo: target, after: after) else { return }
        state.cachedProjects = state.order.sorted(state.cachedProjects)
        appState.sidebarNavigation = state; projects = state.cachedProjects
    }
    private func localRepo(in project: MergedProject?) -> RepoEntry? {
        let members = Set(project?.members.map(\.id) ?? [])
        return appState.repos.first { members.contains(localProjectID($0)) }
    }
    private func projectMenu(_ project: SidebarProject) -> AnyView {
        guard let repo = localRepo(in: mergedSidebar.project(id: project.id)) else { return AnyView(EmptyView()) }
        return AnyView(Group {
            if !repo.isGitTracked {
                Button("Initialize Git Repository") { onInitializeGit(repo) }
            }
            if let forge = forgeLink(for: repo) {
                Button(forge.menuTitle) { NSWorkspace.shared.open(forge.url) }
            }
            Button("Choose Project Icon…") { iconStore.chooseIcon(for: repo.id, state: &appState) }
            Button("Use Initials") {
                if let index = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                    appState.repos[index].iconOverride = .initials(project.displayInitials)
                    iconStore.refreshIcons(appState.repos, force: true)
                }
            }
            Button("Reset Icon to Automatic") {
                if let index = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                    appState.repos[index].iconOverride = nil
                    iconStore.refreshIcons(appState.repos, force: true)
                }
            }
            Divider()
            Button("Remove Repository") { onRemoveRepo(repo) }
        })
    }
    /// Relayed-row contexts for `remoteSection`, keyed as its lookup expects.
    private func relayedRowContexts(_ promoted: [WorktreePanes]) -> [String: SidebarWorktreeContext] {
        Dictionary(promoted.map {
            ((($0.sidebar?.id ?? $0.path) + "\u{0}" + SidebarProjection.projectID($0)), navigation.worktreeContext($0))
        }, uniquingKeysWith: { first, _ in first })
    }
    private func remoteSection(contexts: [String: SidebarWorktreeContext], projectFilter: String?, query: String = "",
                               section: SidebarWorktreeSection = .all, singleRow: RemoteMacsSection.SingleRow? = nil) -> some View {
        RemoteMacsSection(model: remoteMacsModel, expansion: $remoteSectionExpansion, worktreePanesByRemote: displayedRemoteRows,
                          workspaceLayout: remoteWorkspaceLayout,
                          selectedRemoteIdentity: selectedRemoteIdentity, selectedRemoteWorktreePath: selectedRemoteWorktreePath,
                          selectedRemotePaneSessionName: selectedRemotePaneSessionName, theme: theme,
                          onSelectRemoteMac: onSelectRemoteMac, onSelectRemoteWorktree: onSelectRemoteWorktree,
                          onSelectRemotePane: onSelectRemotePane, onAddRemoteWorktree: onAddRemoteWorktree,
                          onDeleteRemoteWorktree: onDeleteRemoteWorktree, onAddRemoteMac: onAddRemoteMac,
                          onSetupLinuxHost: onSetupLinuxHost,
                          projectFilter: projectFilter, query: query,
                          showsMacHierarchy: false,
                          showsRepositoryHeaders: !query.isEmpty,
                          editableProjectIDs: Set(projects.filter { $0.isAvailable && $0.supportsWorktreeEditing == true }.map(\.id)),
                          projects: projects, projectIcons: projectIcons, section: section, singleRow: singleRow,
                          reportController: reportController, contextForWorktree: { row in
                              contexts[(row.sidebar?.id ?? row.path) + "\u{0}" + SidebarProjection.projectID(row)] ?? navigation.worktreeContext(row)
                          })
    }

    private var addRepositoryIconButton: some View {
        Button(action: onAddRepo) {
            Image(systemName: "folder.badge.plus")
                .frame(minWidth: 28, minHeight: 32).contentShape(Rectangle())
                .help("Add Repository")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Repository")
    }

    private var remoteManagementButton: some View {
        Button { showsRemoteManagement.toggle() } label: {
            Image(systemName: "desktopcomputer")
                .frame(minWidth: 28, minHeight: 32).contentShape(Rectangle())
                .help("View and manage remote host connections")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage Remote Hosts")
        .popover(isPresented: $showsRemoteManagement) {
            RemoteMacConnectionsPopover(model: remoteMacsModel, onAddRemoteMac: {
                showsRemoteManagement = false
                onAddRemoteMac()
            }, onSetupLinuxHost: onSetupLinuxHost.map { action in
                {
                    showsRemoteManagement = false
                    action()
                }
            }, onUpdateHost: onUpdateHost.map { action in
                { host in showsRemoteManagement = false; action(host) }
            })
        }
    }

    var body: some View {
        // Explicit dependency: the titles live on TerminalManager, while this
        // lightweight observable scopes invalidation to the sidebar.
        let _ = paneTitleInvalidations.generation
        // Project local and relayed rows once; every section below shares them.
        let local = localWorktrees
        let promoted = remoteMacsModel.promotedWorktreesForRelay()
        let counts = activityCounts(local + promoted)
        let promotedContexts = relayedRowContexts(promoted)
        let merged = mergedSidebar
        let selectedMergedID = merged.selectedProjectID(for: navigation.selectedProjectID)
        // Read native chrome height before expanding underneath it.
        GeometryReader { titleBarGeometry in
        GeometryReader { _ in
        VStack(spacing: 0) {
        Color.clear
            .frame(height: max(titleBarGeometry.safeAreaInsets.top, 40))
            .allowsHitTesting(false)
        searchRow
        HStack(spacing: 0) {
            if showsProjectRail {
                ProjectNavigationRail(projects: merged.projects.map(\.representative), counts: merged.rekeyed(counts.attentionByProject), workingCounts: merged.rekeyed(counts.workingByProject), icons: mergedProjectIcons(merged),
                                      selectedID: selectedMergedID,
                                      collapsed: $navigation.railCollapsed, expandedWidth: $navigation.railExpandedWidth, selectionColor: theme.foreground.opacity(0.16), onSelect: selectProject,

                                      onMove: moveProject, localDeviceID: owner.deviceID,
                                      aboveManagement: { AnyView(voiceDictationButton(collapsed: navigation.railCollapsed)) },
                                      management: { AnyView(HStack(spacing: 0) {
                                          addRepositoryIconButton
                                          remoteManagementButton
                                      }) }, menu: projectMenu)
                Divider()
            }
            VStack(spacing: 0) {
                if let navigationError {
                    Text(navigationError).font(.caption).foregroundStyle(.red).padding(8)
                }
                    ScrollViewReader { proxy in
                        SidebarWorktreeViewport(pinnedMembership: pinnedMembership(in: local + promoted, merged: merged),
                                                showsDivider: navigation.query.isEmpty) {
                            if navigation.query.isEmpty {
                                worktreeRows(section: .pinned, activityCounts: counts, remoteContexts: promotedContexts, merged: merged)
                                    .padding(.horizontal, showsProjectRail ? 6 : 10)
                            }
                        } controls: {
                            if navigation.query.isEmpty {
                                selectedProjectAddWorktreeHeader
                            }
                        } content: {
                            if showsProjectRail {
                                ProjectWorktreeColumn(onDoubleClickEmptySpace: addWorktreeToSelectedProject) {
                                    worktreeRows(section: .tasks, activityCounts: counts, remoteContexts: promotedContexts, merged: merged)
                                }
                            } else {
                                List { worktreeRows(section: .tasks, activityCounts: counts, remoteContexts: promotedContexts, merged: merged) }.listStyle(.sidebar)
                            }
                        }
                        .onChange(of: navigation.selectedProjectID) { _, _ in
                            if let path = navigation.selectedProjectID.flatMap({ navigation.rememberedWorktrees[$0] }) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                    .clipped()
                if !showsProjectRail {
                    Divider()
                    voiceDictationButton(collapsed: false)
                    HStack {
                        Button(action: onAddRepo) { Label("Add Repository", systemImage: "plus") }
                        Spacer()
                        remoteManagementButton
                    }.buttonStyle(.plain).font(.caption).padding(10)
                }
            }.frame(minWidth: 220, maxWidth: .infinity)
        }
        }
        }
        // Reserve the native toolbar hit region above the search field.
        // Its compact variant extends to 40 points even with a smaller inset.
        .ignoresSafeArea(.container, edges: .top)
        }
        .task { await appStateChanges.observe { await refreshNavigation() } }
        .onAppear {
            terminalManager.paneWebURL = { [appState = $appState, webController] terminalID in
                guard case let .listening(_, port) = webController.status, let host = webController.serverHostname else { return nil }
                return Self.paneWebURL(terminalID: terminalID, repos: appState.wrappedValue.repos, host: host, port: port)
            }
        }
        .onChange(of: reportController.activeID) { _, id in
            if id != nil {
                if frozenWorktreeOrder.isEmpty {
                    frozenWorktreeOrder = Dictionary(uniqueKeysWithValues: appState.repos.map { ($0.id, SidebarHostNavigation.displayedWorktrees(in: $0).map(\.id)) })
                    frozenPins = Dictionary(uniqueKeysWithValues: appState.repos.flatMap(\.worktrees).map { ($0.id, $0.isPinned) })
                    frozenRemoteRows = remoteMacsModel.worktreePanesByRemote
                    let merged = mergedSidebar
                    frozenMergedOrder = Dictionary(uniqueKeysWithValues: merged.projects.map { project in
                        (project.id, merged.sections(for: project.id).temporary.map(\.id))
                    })
                }
            } else {
                frozenWorktreeOrder = [:]; frozenPins = [:]; frozenRemoteRows = [:]; frozenMergedOrder = [:]
            }
        }
        .onChange(of: navigation.selectedProjectID) { _, _ in reportController.close() }
        .onChange(of: navigation.query) { _, _ in reportController.close() }
        .onDisappear { reportController.close() }
        .onChange(of: appState.selectedWorktreePath) { old, new in
            rememberSelection(old)
            if let new,
               let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == new } }) {
                navigation.selectedProjectID = mergedSidebar.mergedID(forMember: localProjectID(repo))
                rememberSelection(new)
            }
        }
        .onRemoteWorktreeSelectionChange(identity: selectedRemoteIdentity, path: selectedRemoteWorktreePath) { _ in
            rememberRemoteSelection()
            if let identity = selectedRemoteIdentity, let path = selectedRemoteWorktreePath,
               let row = remoteMacsModel.worktreePanesByRemote[identity]?.first(where: { $0.path == path }) {
                navigation.selectedProjectID = mergedSidebar.mergedID(forMember: SidebarProjection.projectID(row))
            }
        }
        .onChange(of: showsProjectRail) { _, enabled in
            onNavigationIntent()
            reportController.close()
            navigation.query = ""
            let delta = navigation.railWidth + 1
            appState.sidebarWidth = max(enabled ? delta + 220 : 220, appState.sidebarWidth + (enabled ? delta : -delta))
        }
        .onChange(of: navigation.railWidth) { previous, current in
            guard showsProjectRail else { return }
            appState.sidebarWidth = max(current + 221, appState.sidebarWidth + current - previous)
        }
        .themedSidebarSurface(theme.core)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .publishSidebarWidth()
        .sheet(item: $pendingAddWorktree) { request in
            AddWorktreeSheet(
                repoDisplayName: request.repo.displayName,
                initialWorktreeName: request.prefill,
                branchEntries: currentBranchEntries(forRepo: request.repo),
                defaultBranchStatus: defaultBranchStatus(
                    for: request.repo,
                    stats: statsStore.stats[request.repo.path]
                ),
                onPullDefaultBranch: {
                    await pullDefaultBranch(for: request.repo)
                },
                onSubmit: { worktreeName, branch, agent in
                    let err = await onAddWorktree(request.repo, worktreeName, branch, agent)
                    if err == nil { pendingAddWorktree = nil }
                    return err
                },
                onCancel: { pendingAddWorktree = nil }
            )
        }
    }

    private var searchRow: some View {
        SidebarSearchField(query: $navigation.query)
            .frame(height: 30)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
    }

    private func voiceDictationButton(collapsed: Bool) -> some View {
        VoiceDictationButton(
            controller: voiceDictation,
            target: selectedVoicePaneID.flatMap { terminalManager.handle(for: $0) },
            collapsed: collapsed
        )
    }

    @ViewBuilder
    private func worktreeRows(section: SidebarWorktreeSection, activityCounts counts: SidebarActivityCounts,
                              remoteContexts: [String: SidebarWorktreeContext], merged: SidebarMergedRows) -> some View {
        if navigation.query.isEmpty {
            let selected = merged.selectedProjectID(for: navigation.selectedProjectID)
            ForEach(merged.projects.filter { !showsProjectRail || $0.id == selected }) { project in
                mergedProjectSection(project, merged: merged, section: section, counts: counts, remoteContexts: remoteContexts)
            }
        } else {
            remoteSection(contexts: remoteContexts, projectFilter: nil, query: navigation.query)
            ForEach(appState.repos) { repo in
                let labels = SidebarWorktreeLabel.texts(for: repo.worktrees, inRepoAtPath: repo.path,
                    defaultBranch: remoteBranchStore.resolvedDefaultBranch(forRepoAt: repo.path, hint: repo.defaultBranchHint))
                ForEach(displayedWorktrees(in: repo).filter {
                    contextForLocalWorktree($0, repo: repo, displayName: labels[$0.id] ?? $0.branch).matches(query: navigation.query)
                }) { worktree in
                    worktreeBlock(worktree, repo: repo, displayName: "\(repo.displayName) / \(labels[worktree.id] ?? worktree.branch)", activityCounts: counts)
                }
            }
        }
    }

    /// Builds the eligible-branch list for the Add Worktree sheet,
    /// merging the latest remote-branch snapshot with the repo's
    /// currently-mounted branches (so the picker can dim/disable them)
    /// and any in-flight PR metadata. `filterText` is "" — the
    /// `BranchPicker` does live-filtering against the full list itself.
    private func currentBranchEntries(forRepo repo: RepoEntry) -> [BranchPickerEntry] {
        let snapshot = remoteBranchStore.branchesByRepo[repo.path] ?? RemoteBranchSnapshot()
        var mounted: [String: String] = [:]
        for wt in repo.worktrees where wt.state.hasOnDiskWorktree {
            mounted[wt.branch] = wt.path
        }
        let prs = prStatusStore.prsByRepoBranch[repo.path] ?? [:]
        return BranchPickerViewModel.entries(
            branchSnapshot: snapshot,
            mountedBranchToPath: mounted,
            prsByBranch: prs,
            filterText: ""
        )
    }

    private func pullDefaultBranch(for repo: RepoEntry) async -> String? {
        guard let status = defaultBranchStatus(
            for: repo,
            stats: statsStore.stats[repo.path]
        ) else {
            return nil
        }
        do {
            try await GitDefaultBranchPull.pull(repoPath: repo.path, branchName: status.branchName)
        } catch GitDefaultBranchPull.Error.gitFailed(_, let stderr) {
            return stderr
        } catch {
            return "\(error)"
        }
        let branch = repo.worktrees.first(where: { $0.path == repo.path })?.branch ?? ""
        statsStore.refresh(worktreePath: repo.path, repoPath: repo.path, branch: branch)
        return nil
    }

    /// Title + destination for the repo's "Open on <forge>…"
    /// context-menu item, or nil when the origin is unresolved or
    /// unsupported, in which case the menu omits the item
    /// (PROJECT-2.2).
    private func forgeLink(
        for repo: RepoEntry
    ) -> (menuTitle: String, url: URL)? {
        guard let origin = prStatusStore.originByRepo[repo.path],
              let presentation = ForgePresentation(origin: origin),
              let url = origin.webURL else { return nil }
        return (presentation.menuTitle, url)
    }

    private func mergedProjectIcons(_ merged: SidebarMergedRows) -> [String: Data] {
        let icons = projectIcons
        var result: [String: Data] = [:]
        for project in merged.projects {
            if let member = project.iconMember { result[project.id] = icons[member.id] }
        }
        return result
    }

    private func pinnedCollapsed(_ project: MergedProject) -> Binding<Bool> {
        let key = "sidebar.pinned.collapsed.\(project.id)"
        if let repo = localRepo(in: project) {
            return Binding(
                get: { appState.repos.first { $0.id == repo.id }?.isPinnedCollapsed ?? false },
                set: { collapsed in
                    if let index = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                        appState.repos[index].isPinnedCollapsed = collapsed
                    }
                })
        }
        return Binding(get: { UserDefaults.standard.bool(forKey: key) }, set: { UserDefaults.standard.set($0, forKey: key) })
    }

    @ViewBuilder
    private func mergedProjectSection(_ project: MergedProject, merged: SidebarMergedRows, section: SidebarWorktreeSection,
                                      counts: SidebarActivityCounts, remoteContexts: [String: SidebarWorktreeContext]) -> some View {
        let rows = mergedProjectRows(project, merged: merged, section: section, counts: counts, remoteContexts: remoteContexts)
        if showsProjectRail {
            rows
        } else if let repo = localRepo(in: project) {
            DisclosureGroup(isExpanded: Binding(
                get: { !repo.isCollapsed },
                set: { expanded in
                    if let index = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                        appState.repos[index].isCollapsed = !expanded
                    }
                }
            )) { rows } label: {
                HStack(spacing: 6) {
                    Text(project.name).foregroundColor(theme.foreground).fontWeight(.semibold)
                    Spacer()
                    if SidebarMenuVisibility.showsAddWorktree(repo: repo) { addWorktreeButton(repo, showsLabel: false) }
                }
                .contextMenu { projectMenu(project.representative) }
            }
        } else {
            let key = "project:" + project.id
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsedMergedFolders.contains(key) },
                set: { expanded in
                    if expanded { collapsedMergedFolders.remove(key) } else { collapsedMergedFolders.insert(key) }
                }
            )) { rows } label: {
                Text(project.name).foregroundColor(theme.foreground).fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private func mergedProjectRows(_ project: MergedProject, merged: SidebarMergedRows, section: SidebarWorktreeSection,
                                   counts: SidebarActivityCounts, remoteContexts: [String: SidebarWorktreeContext]) -> some View {
        let sections = merged.sections(for: project.id, frozenOrder: frozenMergedOrder[project.id])
        let collapsed = pinnedCollapsed(project)
        if section != .tasks {
            let header = SidebarWorktreeSectionHeader("Pinned Agents", color: theme.sidebarDimIcon, isCollapsed: collapsed, separatesPrecedingRows: false)
                .listRowInsets(EdgeInsets(top: 0, leading: showsProjectRail ? 0 : -20, bottom: 0, trailing: 0))
            if let repo = localRepo(in: project) {
                header.modifier(PinnedWorktreeDropTarget(repoID: repo.id, appState: $appState, isEnabled: navigation.query.isEmpty))
            } else {
                header
            }
            if !collapsed.wrappedValue {
                mergedNodes(sections.pinned, projectID: project.id, depth: 0, counts: counts, remoteContexts: remoteContexts)
                if sections.pinned.isEmpty {
                    Text("Right-click a worktree to pin it here.")
                        .font(.caption)
                        .foregroundColor(theme.sidebarDimIcon)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            }
        }
        if section != .pinned {
            ForEach(sections.temporary) { row in
                mergedRow(row, counts: counts, remoteContexts: remoteContexts)
            }
        }
    }

    private func mergedNodes(_ nodes: [MergedWorktreeNode], projectID: String, depth: Int, counts: SidebarActivityCounts,
                             remoteContexts: [String: SidebarWorktreeContext]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            switch node {
            case .row(let row):
                mergedRow(row, counts: counts, remoteContexts: remoteContexts)
            case .folder(let id, let name, let children):
                let key = projectID + "\u{0}" + id
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsedMergedFolders.contains(key) },
                    set: { expanded in
                        if expanded { collapsedMergedFolders.remove(key) } else { collapsedMergedFolders.insert(key) }
                    }
                )) {
                    mergedNodes(children, projectID: projectID, depth: depth + 1, counts: counts, remoteContexts: remoteContexts)
                        .padding(.leading, showsProjectRail ? 16 : 0)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(theme.sidebarDimIcon)
                        Text(name)
                            .lineLimit(1)
                            .foregroundColor(theme.sidebarPrimaryText(isActive: false))
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
        })
    }

    /// One row, drawn by whichever view owns its data: local rows read live
    /// terminal state, remote rows read their host's report.
    @ViewBuilder
    private func mergedRow(_ row: MergedWorktreeRow, counts: SidebarActivityCounts,
                           remoteContexts: [String: SidebarWorktreeContext]) -> some View {
        if row.hostID == owner.deviceID,
           let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == row.row.path } }),
           let worktree = displayedWorktrees(in: repo).first(where: { $0.path == row.row.path }) {
            worktreeBlock(worktree, repo: repo, displayName: row.leafName, activityCounts: counts,
                          hostLabel: row.showsHostLabel ? "This Mac" : nil)
                .modifier(MergedRowInsets(projectColumn: showsProjectRail))
        } else if let mac = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == row.hostID }) {
            remoteSection(contexts: remoteContexts, projectFilter: nil, singleRow: .init(worktree: row.row, remoteMac: mac, displayName: row.leafName,
                          hostLabel: row.showsHostLabel ? row.hostLabel : nil))
                .modifier(MergedRowInsets(projectColumn: showsProjectRail))
        }
    }

    private func addWorktreeButton(_ repo: RepoEntry, showsLabel: Bool) -> some View {
        Button { presentAddWorktree(for: repo) } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                if showsLabel { Text("Add worktree") }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(theme.sidebarDimIcon)
            .frame(minWidth: 18, minHeight: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add worktree to \(repo.displayName)")
        .accessibilityLabel("Add worktree to \(repo.displayName)")
    }

    private func presentAddWorktree(for repo: RepoEntry) {
        remoteBranchStore.pulse()
        prStatusStore.pulse()
        pendingAddWorktree = AddWorktreeRequest(repo: repo, prefill: "")
    }

    @ViewBuilder
    private var selectedProjectAddWorktreeHeader: some View {
        if navigation.query.isEmpty,
           let project = addWorktreeTarget {
            let repo = appState.repos.first { localProjectID($0) == project.id }
            let canAdd = canAddWorktree(to: project)
            if repo != nil || project.owner != nil {
                let add = Group {
                    if canAdd {
                        Button(action: addWorktreeToSelectedProject) {
                            Label("Add worktree", systemImage: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.vertical, 3)
                        }
                        .disabled(repo == nil && remoteProjectOperationInProgress)
                        .modifier(SidebarAddWorktreeButtonAppearance())
                        .controlSize(.regular)
                        .foregroundStyle(theme.foreground)
                        .fixedSize()
                        .help("Add worktree to \(project.name)")
                        .accessibilityLabel("Add worktree to \(project.name)")
                    }
                }
                HStack(spacing: 8) { Spacer(minLength: 0); add }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    /// The selected project's checkout that Add worktree targets: this Mac's,
    /// otherwise the first host that's available.
    private var addWorktreeTarget: SidebarProject? {
        let merged = mergedSidebar
        guard let project = merged.project(id: merged.selectedProjectID(for: navigation.selectedProjectID)) else { return nil }
        let available = project.members.filter(\.isAvailable)
        return available.first { $0.owner?.deviceID == owner.deviceID } ?? available.first
    }

    private func canAddWorktree(to project: SidebarProject) -> Bool {
        if let repo = appState.repos.first(where: { localProjectID($0) == project.id }) {
            return SidebarMenuVisibility.showsAddWorktree(repo: repo)
        }
        return remoteMacsModel.editableRepositoryTarget(for: project) != nil
    }

    private func addWorktreeToSelectedProject() {
        guard navigation.query.isEmpty, let project = addWorktreeTarget else { return }

        if let repo = appState.repos.first(where: { localProjectID($0) == project.id }) {
            if SidebarMenuVisibility.showsAddWorktree(repo: repo) { presentAddWorktree(for: repo) }
            return
        }

        guard !remoteProjectOperationInProgress else { return }
        remoteProjectOperationInProgress = true
        navigationError = nil
        Task { @MainActor in
            defer { remoteProjectOperationInProgress = false }
            do {
                let (mac, repository) = try await remoteMacsModel.addWorktreeRepository(for: project)
                onAddRemoteWorktree(mac, repository)
            } catch { navigationError = error.localizedDescription }
        }
    }

    /// Renders a worktree and its status line as one block, with a single
    /// rounded highlight when it's active.
    @ViewBuilder
    private func worktreeBlock(
        _ worktree: WorktreeEntry,
        repo: RepoEntry,
        displayName: String,
        activityCounts: SidebarActivityCounts,
        hostLabel: String? = nil
    ) -> some View {
        let isActive = appState.selectedWorktreePath == worktree.path && selectedRemoteIdentity == nil
        let context = contextForLocalWorktree(worktree, repo: repo, displayName: displayName)
        let status = SidebarRowStatus.resolve(context: context, worktree: context.worktree, isAsleep: false)
        let projectID = localProjectID(repo)
        let project = projects.first { $0.id == projectID }
            ?? SidebarProject(id: projectID, repositoryID: repo.id.uuidString, name: repo.displayName)
        let prBadge = prStatusStore.infos[worktree.path].map {
            PRBadge(number: $0.number, state: $0.state, checks: $0.checks,
                    mergeable: $0.mergeable, url: $0.url)
        }
        let heading = WorktreeRow(
            entry: worktree,
            isActive: isActive,
            displayName: displayName,
            isMainCheckout: worktree.path == repo.path,
            theme: theme,
            stats: statsStore.stats[worktree.path],
            baseRef: statsStore.baseRef(
                worktreePath: worktree.path,
                repoPath: repo.path
            ),
            prBadge: prBadge,
            attentionStyle: nil,
            attentionCount: max(activityCounts.attentionByWorktree[worktree.path, default: 0], status.needsAttention ? 1 : 0),
            project: project, projectIconData: iconStore.iconData(for: repo), hostLabel: hostLabel,
            identityMenu: worktree.path == repo.path ? nil : { anchor in
                WorktreeEmojiMenu.build(hasEmoji: worktree.emoji != nil,
                                        onChange: { editWorktreeEmoji(worktree, anchoredTo: anchor) },
                                        onClear: { SidebarHostNavigation.clearEmoji(worktreeID: worktree.id, in: &appState.repos) })
            },
            onRemove: { window in onDeleteWorktree(worktree.path, window) }
        )
        .frame(minHeight: 24)
        .overlay(alignment: .trailing) {
            SleepingWorktreeIndicator(state: terminalManager.worktreeSleepState, path: worktree.path)
        }
        .contentShape(Rectangle())
        WorktreeBlock(
            worktree: worktree, repoID: repo.id, isActive: isActive,
            theme: theme, appState: $appState,
            reorderingEnabled: navigation.query.isEmpty,
            onSelect: { onSelect(worktree.path) },
            menu: { anchor in buildWorktreeMenu(worktree, repo: repo, window: anchor.window) }
        ) {
            heading
        } status: {
            SidebarWorktreeStatusTarget(status: status, secondary: theme.sidebarSecondaryText) {
                Task { _ = await openReport(context) }
            }
        }
    }

    /// Worktree row's right-click menu. Built as `NSMenu` (not a
    /// SwiftUI `.contextMenu`) for the List-row hoisting reason
    /// `.rightClickMenu` documents. Reordering is drag-only and the
    /// emoji identity has its own menu on the identity slot
    /// (LAYOUT-2.96), so neither appears here.
    private func buildWorktreeMenu(_ worktree: WorktreeEntry, repo: RepoEntry, window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        // In-flight rows have nothing the menu actions can act on
        // safely — Open-in-Finder, Stop, and Delete-Worktree would all
        // either error or race the flow that owns the placeholder.
        if worktree.state.isInFlight {
            return menu
        }
        var hasPinnedActions = false
        if worktree.path != repo.path && (worktree.isPinned || worktree.state.hasOnDiskWorktree) {
            menu.addItem(ClosureMenuItem(title: worktree.isPinned ? "Unpin Agent" : "Pin Agent") {
                SidebarHostNavigation.setPinned(!worktree.isPinned, worktreeID: worktree.id, in: &appState.repos)
            })
            hasPinnedActions = true
        }
        if SidebarMenuVisibility.showsEditRoleInstructions(worktree: worktree, repo: repo) {
            let key = InstructionKey.key(worktreePath: worktree.path, repoPath: repo.path,
                defaultBranch: remoteBranchStore.resolvedDefaultBranch(forRepoAt: repo.path, hint: repo.defaultBranchHint))
            menu.addItem(ClosureMenuItem(title: "Edit Role Instructions…") {
                editRoleInstructions(key: key, worktree: worktree, repo: repo)
            })
            hasPinnedActions = true
        }
        if let title = GitAutoTracking.menuTitle(worktree: worktree, repo: repo) {
            let item = ClosureMenuItem(title: title) {
                guard GitAutoTracking.setEnabled(!worktree.autoTrackEnabled, worktreeID: worktree.id, in: &appState.repos) else { return }
                statsStore.autoTracking.reset(worktreePath: worktree.path)
                statsStore.refresh(worktreePath: worktree.path, repoPath: repo.path, branch: worktree.branch)
                statsStore.refreshAutoTracking(repoPath: repo.path)
            }
            item.state = worktree.autoTrackEnabled ? .on : .off
            menu.addItem(item)
            hasPinnedActions = true
        }
        if hasPinnedActions { menu.addItem(.separator()) }
        if worktree.state != .stale {
            menu.addItem(ClosureMenuItem(title: "Open Worktree in Finder...") {
                NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path))
            })
            menu.addItem(.separator())
        }
        if worktree.state == .running {
            let keepsAwake = WorktreeSleepPreferences.keepsAwake(worktree.path)
            let awakeItem = ClosureMenuItem(title: "Keep Awake") {
                WorktreeSleepPreferences.setKeepsAwake(!keepsAwake, path: worktree.path)
                _ = terminalManager.wakeWorktree(worktree.path)
            }
            awakeItem.state = keepsAwake ? .on : .off
            menu.addItem(awakeItem)
            menu.addItem(ClosureMenuItem(title: "Stop") { [self] in
                onStopWorktree(worktree.path)
            })
        }
        if worktree.state == .stale {
            menu.addItem(ClosureMenuItem(title: "Dismiss") {
                dismissWorktree(worktree)
            })
        }
        // git refuses to remove the main checkout, so hiding the item
        // there avoids a guaranteed error path.
        if SidebarMenuVisibility.showsDeleteWorktree(worktree: worktree, repo: repo)
            && worktree.state != .stale {
            menu.addItem(ClosureMenuItem(title: "Delete Worktree") { [self] in
                guard let window else { return }
                onDeleteWorktree(worktree.path, window)
            })
        }
        // TEAM-7.2: every tracked repository is a team, so each worktree
        // row opens its repository's activity-log window.
        menu.addItem(.separator())
        let teamWindowID = TeamActivityLogWindowID(
            teamID: TeamLookup.id(forRepoPath: repo.path),
            teamName: repo.displayName
        )
        let openWindow = self.openWindow
        menu.addItem(ClosureMenuItem(title: "Show Team Activity…") {
            openWindow(id: TeamActivityLogWindowID.windowGroupID, value: teamWindowID)
        })
        return menu
    }

    private func editRoleInstructions(key: String?, worktree: WorktreeEntry, repo: RepoEntry) {
        Task { @MainActor in
            do {
                let url = try await InstructionStore.prepareRoleFile(key: key, repoPath: repo.path, worktreePath: worktree.path)
                guard let path = SidebarMenuVisibility.roleEditorDestination(worktree: worktree, repo: repo, state: appState) else {
                    navigationError = "This pinned worktree changed while opening its role instructions. Try again."
                    return
                }
                onSelect(path)
                guard let current = appState.worktree(forPath: path), current.state == .running,
                      let source = current.focusedPaneSlotID.flatMap({ current.splitTree.containsLeaf($0) ? $0 : nil })
                        ?? current.splitTree.allLeaves.first,
                      terminalManager.openURL(url.absoluteString, from: source) else {
                    navigationError = "Could not open role instructions at \(url.path)."
                    return
                }
            } catch {
                navigationError = "Could not open role instructions: \(error.localizedDescription)"
            }
        }
    }

    /// LAYOUT-2.97: the native emoji palette, anchored at the identity slot.
    private func editWorktreeEmoji(_ worktree: WorktreeEntry, anchoredTo anchor: NSView) {
        WorktreeEmojiPaletteCapture.present(anchoredTo: anchor) { chosen in
            guard !SidebarHostNavigation.setManualEmoji(chosen, worktreeID: worktree.id, in: &appState.repos) else { return }
            let error = NSAlert()
            error.messageText = "Choose one unused emoji"
            error.runModal()
        }
    }


    /// AppKit-side pane right-click menu (PWD-1.1 / PWD-1.3 / LAYOUT-2.7
    /// / TERM-8.10). The Move section is shared with the terminal-surface
    /// menu via `PaneMoveMenuBuilder`; the Copy-web-URL item is sidebar-
    /// only because the surface has no worktree-context-free way to know
    /// its session name without going through this same view tree.
    static func paneWebURL(terminalID: PaneSlotID, repos: [RepoEntry], host: String, port: Int) -> String? {
        guard let session = repos.lazy.flatMap(\.worktrees).compactMap({ $0.paneSessions[terminalID] }).first else { return nil }
        return WebURLComposer.url(session: ZmxLauncher.sessionName(for: session), host: host, port: port)
    }

    private func dismissWorktree(_ worktree: WorktreeEntry) {
        StaleWorktreeDismissal.dismiss(
            worktreeID: worktree.id,
            appState: $appState,
            destroySurfaces: {
                terminalManager.destroySurfaces(terminalIDs: $0)
            },
            clearPRStatus: {
                prStatusStore.clear(worktreePath: $0)
            },
            clearStats: {
                statsStore.clear(worktreePath: $0)
            }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let path = url.path
                DispatchQueue.main.async {
                    onAddPath(path)
                }
            }
        }
        return true
    }
}

extension View {
    func onRemoteWorktreeSelectionChange(
        identity: RemoteMacIdentity?,
        path: String?,
        perform action: @escaping (RemoteMacSidebarSelection?) -> Void
    ) -> some View {
        let selection = identity.map {
            RemoteMacSidebarSelection(identity: $0, worktreePath: path)
        }
        return onChange(of: selection) { _, current in action(current) }
    }
}

/// Worktree rows use a compact List outdent relative to their parent. Keep
/// that treatment on leaf rows at every depth: a folder owns a native
/// disclosure column, while its worktree children should advance by the same
/// visual amount that a direct worktree advances beneath a repository.
/// Matches the outdent nested rows have always had in the project-less list.
struct MergedRowInsets: ViewModifier {
    let projectColumn: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if projectColumn {
            content
        } else {
            content.listRowInsets(EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0)).listRowSeparator(.hidden)
        }
    }
}
