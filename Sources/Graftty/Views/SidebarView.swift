import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

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

/// @spec LAYOUT-2.62: When the project rail setting changes, the application shall place Add Repository beside Manage Remote Macs in the project footer if enabled, or retain the labeled Add Repository button in the single-sidebar footer if disabled.

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
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onRemoveRepo: (RepoEntry) -> Void
    let onInitializeGit: (RepoEntry) -> Void
    let onStopWorktree: (String) -> Void
    let onDeleteWorktree: (String, NSWindow) -> Void
    let onMovePane: (PaneSlotID, String) -> Void
    /// Called when the user submits the add-worktree sheet. Returns nil
    /// on success, or a user-visible error string (typically git's
    /// stderr) on failure so the sheet can display it inline.
    let onAddWorktree: (RepoEntry, String, BranchSelection) async -> String?

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

    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false

    /// Hovered drop-target row during a pane drag (PWD-1.5). Nil otherwise.
    @State private var dropTargetWorktreeID: WorktreeEntry.ID?

    /// Virtual folders start expanded. Only explicit user collapses are
    /// retained, scoped by repository so same-named folders do not share UI
    /// state across projects.
    @State private var worktreeFolderExpansion = SidebarWorktreeFolderExpansion()
    @State private var remoteSectionExpansion = RemoteSidebarExpansion()

    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    @State private var navigation = SidebarNavigationState(prefix: "sidebar.mac")
    @StateObject private var reportController = SidebarReportController()
    @State private var frozenWorktreeOrder: [UUID: [UUID]] = [:]
    @State private var frozenPins: [UUID: Bool] = [:]
    @State private var frozenRemoteRows: [RemoteMacIdentity: [WorktreePanes]] = [:]
    @ObservedObject private var iconStore = SidebarHostController.shared
    @State private var projects: [SidebarProject] = []
    @State private var navigationError: String?
    @State private var showsRemoteManagement = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var owner: WorktreeOrigin { iconStore.owner }
    private func localProjectID(_ repo: RepoEntry) -> String { "\(owner.deviceID.value):\(repo.id.uuidString)" }
    private var orderedSidebarRepos: [RepoEntry] {
        let positions = Dictionary(projects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        return appState.repos.enumerated().sorted {
            let left = positions[localProjectID($0.element), default: .max]
            let right = positions[localProjectID($1.element), default: .max]
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    private var localWorktrees: [WorktreePanes] {
        sidebarLocalWorktrees(state: appState, owner: owner, titles: terminalManager.displayTitles,
            liveness: claudeSessionRegistry.livenessBySession, prBadges: prStatusStore.infos.mapValues { PRBadge(from: $0) },
            defaultBranch: { remoteBranchStore.resolvedDefaultBranch(forRepoAt: $0.path, hint: $0.defaultBranchHint) })
    }
    private var activity: [SidebarActivityItem] {
        SidebarProjection.activity(localWorktrees + remoteMacsModel.promotedWorktreesForRelay())
    }
    private var activityCounts: SidebarActivityCounts {
        let rows = localWorktrees + remoteMacsModel.promotedWorktreesForRelay()
        let pending = rows.flatMap { navigation.worktreeContext($0).pending }
        let working = SidebarProjection.activity(rows).filter(\.isBusy).map { item in
            var item = item
            item.occurrence = nil
            return item
        }
        return SidebarActivityCounts(items: pending + working)
    }

    private var pendingNavigationRows: [WorktreePanes] {
        let local = Dictionary(localWorktrees.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let promoted = remoteMacsModel.promotedWorktreesForRelay()
        let remote = displayedRemoteRows
        func localRows(_ nodes: [SidebarWorktreeNode]) -> [WorktreePanes] {
            nodes.flatMap { node in
                switch node {
                case .worktree(let row, _): return local[row.path].map { [$0] } ?? []
                case .folder(_, _, let children): return localRows(children)
                }
            }
        }
        return [SidebarWorktreeSection.pinned, .tasks].flatMap { section in
            let localSectionRows = orderedSidebarRepos.flatMap { repo in
                let rows = displayedWorktrees(in: repo).filter {
                    SidebarHostNavigation.isPinned($0, in: repo) == (section == .pinned)
                }
                return localRows(SidebarWorktreeHierarchy.nodes(for: rows, inRepoAtPath: repo.path,
                    defaultBranch: remoteBranchStore.resolvedDefaultBranch(forRepoAt: repo.path, hint: repo.defaultBranchHint)))
            }
            let remoteRows = remoteMacsModel.savedRemoteMacs.flatMap { mac in
                let rows = (remote[RemoteMacIdentity(mac)] ?? []).filter { ($0.origin?.relayDepth ?? 0) == 0 }
                var seen: Set<String> = []
                let projects = rows.map(SidebarProjection.projectID).filter { seen.insert($0).inserted }
                return projects.flatMap { id in
                    SidebarWorktreeReportOrder.displayedWorktrees(rows.filter { SidebarProjection.projectID($0) == id }, section: section)
                }.compactMap { raw in
                    promoted.first { $0.sidebar?.id == raw.sidebar?.id && SidebarProjection.projectID($0) == SidebarProjection.projectID(raw) }
                }
            }
            return localSectionRows + remoteRows
        }
    }

    private func contextForLocalWorktree(_ worktree: WorktreeEntry, repo: RepoEntry, displayName: String) -> SidebarWorktreeContext {
        navigation.worktreeContext(sidebarLocalWorktree(worktree, repo: repo, owner: owner,
            displayName: displayName, titles: terminalManager.displayTitles,
            liveness: claudeSessionRegistry.livenessBySession,
            prBadge: prStatusStore.infos[worktree.path].map { PRBadge(from: $0) }))
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

    @ViewBuilder private var pendingNavigationButton: some View {
        let projectFilter = SidebarLayoutPolicy.projectFilter(selectedID: navigation.selectedProjectID, showsProjectRail: showsProjectRail)
        let rows = pendingNavigationRows.filter { $0.state.hasOnDiskWorktree && (projectFilter == nil || SidebarProjection.projectID($0) == projectFilter) }
        let count = rows.filter { !navigation.worktreeContext($0).pending.isEmpty }.count
        if count > 0 {
            Button("\(count) pending") {
                let selected: String? = {
                    if let identity = selectedRemoteIdentity, let path = selectedRemoteWorktreePath {
                        return rows.first {
                            guard let route = remoteMacsModel.relayRouter.resolveWorktree($0.path) else { return false }
                            return route.identity == identity && route.path == path
                        }?.path
                    }
                    return appState.selectedWorktreePath
                }()
                if let item = navigation.nextPendingWorktree(in: rows, projectID: projectFilter, after: selected),
                   let row = rows.first(where: { $0.path == item.worktreeID }) {
                    Task { _ = await openReport(navigation.worktreeContext(row)) }
                }
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange).padding(.vertical, 5)
                .accessibilityHint("Open the next worktree with a pending request")
        }
    }

    private var projectIcons: [String: Data] {
        var result = iconStore.remoteIcons
        for repo in appState.repos { result[localProjectID(repo)] = iconStore.iconData(for: repo) }
        return result
    }
    private func refreshNavigation() async {
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
        if navigation.selectedProjectID == nil || !projects.contains(where: { $0.id == navigation.selectedProjectID }) {
            navigation.selectedProjectID = appState.repos.first(where: { repo in repo.worktrees.contains { $0.path == appState.selectedWorktreePath } }).map(localProjectID) ?? projects.first?.id
        }
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
        guard let path, let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == path } }) else { return }
        navigation.rememberedWorktrees[localProjectID(repo)] = path
    }
    private func rememberRemoteSelection() {
        guard let identity = selectedRemoteIdentity, let path = selectedRemoteWorktreePath,
              let row = remoteMacsModel.worktreePanesByRemote[identity]?.first(where: { $0.path == path }) else { return }
        navigation.rememberedWorktrees[SidebarProjection.projectID(row)] = path
    }
    private func selectProject(_ project: SidebarProject) {
        onNavigationIntent()
        rememberSelection(appState.selectedWorktreePath)
        rememberRemoteSelection()
        navigation.showProject(project.id); navigationError = nil
        guard project.isAvailable else { navigationError = "The owning Mac is offline. Use Manage Remote Macs to reconnect."; return }
        if let index = appState.repos.firstIndex(where: { localProjectID($0) == project.id }) {
            appState.repos[index].isCollapsed = false
            let repo = appState.repos[index]
            let path = navigation.rememberedWorktrees[project.id].flatMap { saved in repo.worktrees.first { $0.path == saved }?.path } ?? repo.worktrees.first?.path
            if let path { onSelect(path) }
        } else if let mac = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == project.owner?.deviceID }) {
            let rows = (remoteMacsModel.worktreePanesByRemote[RemoteMacIdentity(mac)] ?? []).filter { SidebarProjection.projectID($0) == project.id }
            let remembered = navigation.rememberedWorktrees[project.id]
                .flatMap { remoteMacsModel.relayRouter.resolveWorktree($0)?.path ?? $0 }
            if let target = rows.first(where: { $0.path == remembered }) ?? rows.first {
                onSelectRemoteWorktree(mac, target.path)
            }
        }
    }
    private func moveProject(_ id: String, _ target: String, _ after: Bool) {
        guard var state = appState.sidebarNavigation else { return }
        guard state.order.move(id, relativeTo: target, after: after) else { return }
        state.cachedProjects = state.order.sorted(state.cachedProjects)
        appState.sidebarNavigation = state; projects = state.cachedProjects
    }
    private func projectMenu(_ project: SidebarProject) -> AnyView {
        guard let repo = appState.repos.first(where: { localProjectID($0) == project.id }) else { return AnyView(EmptyView()) }
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
    private func remoteSection(projectFilter: String?, query: String = "", section: SidebarWorktreeSection = .all) -> some View {
        let promoted = remoteMacsModel.promotedWorktreesForRelay()
        let contexts = Dictionary(promoted.map {
            ((($0.sidebar?.id ?? $0.path) + "\u{0}" + SidebarProjection.projectID($0)), navigation.worktreeContext($0))
        }, uniquingKeysWith: { first, _ in first })
        return RemoteMacsSection(model: remoteMacsModel, expansion: $remoteSectionExpansion, worktreePanesByRemote: displayedRemoteRows,
                          selectedRemoteIdentity: selectedRemoteIdentity, selectedRemoteWorktreePath: selectedRemoteWorktreePath,
                          selectedRemotePaneSessionName: selectedRemotePaneSessionName, theme: theme,
                          onSelectRemoteMac: onSelectRemoteMac, onSelectRemoteWorktree: onSelectRemoteWorktree,
                          onSelectRemotePane: onSelectRemotePane, onAddRemoteWorktree: onAddRemoteWorktree,
                          onDeleteRemoteWorktree: onDeleteRemoteWorktree, onAddRemoteMac: onAddRemoteMac,
                          onSetupLinuxHost: onSetupLinuxHost,
                          projectFilter: projectFilter, query: query,
                          showsMacHierarchy: !showsProjectRail,
                          showsRepositoryHeaders: !showsProjectRail || !query.isEmpty,
                          editableProjectIDs: Set(projects.filter { $0.isAvailable && $0.supportsWorktreeEditing == true }.map(\.id)),
                          projects: projects, projectIcons: projectIcons, section: section,
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
                .help("View and manage remote Mac connections")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage Remote Macs")
        .popover(isPresented: $showsRemoteManagement) {
            RemoteMacConnectionsPopover(model: remoteMacsModel, onAddRemoteMac: {
                showsRemoteManagement = false
                onAddRemoteMac()
            }, onSetupLinuxHost: onSetupLinuxHost.map { action in
                {
                    showsRemoteManagement = false
                    action()
                }
            })
        }
    }

    var body: some View {
        // Explicit dependency: the titles live on TerminalManager, while this
        // lightweight observable scopes invalidation to the sidebar.
        let _ = paneTitleInvalidations.generation
        let counts = activityCounts
        // Read native chrome height before expanding underneath it.
        GeometryReader { titleBarGeometry in
        GeometryReader { _ in
        VStack(spacing: 0) {
        searchRow(height: max(titleBarGeometry.safeAreaInsets.top, Self.searchRowMinimumHeight))
        HStack(spacing: 0) {
            if showsProjectRail {
                ProjectNavigationRail(projects: projects, counts: counts.attentionByProject, workingCounts: counts.workingByProject, icons: projectIcons,
                                      selectedID: navigation.selectedProjectID,
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
                        SidebarWorktreeViewport {
                            if navigation.query.isEmpty {
                                worktreeRows(section: .pinned, activityCounts: counts)
                                    .padding(.horizontal, showsProjectRail ? 6 : 10)
                            }
                        } controls: {
                            if navigation.query.isEmpty {
                                VStack(spacing: 0) {
                                    SidebarWorktreeDivider().frame(height: 1).allowsHitTesting(false)
                                    selectedProjectAddWorktreeHeader
                                    pendingNavigationButton
                                        .padding(.horizontal, showsProjectRail ? 6 : 10)
                                }
                            }
                        } content: {
                            if showsProjectRail {
                                ProjectWorktreeColumn(onDoubleClickEmptySpace: addWorktreeToSelectedProject) {
                                    worktreeRows(section: .tasks, activityCounts: counts)
                                }
                                .emptySpaceMenu(selectedProjectEmptySpaceMenu)
                            } else {
                                List { worktreeRows(section: .tasks, activityCounts: counts) }.listStyle(.sidebar)
                            }
                        }
                        .onChange(of: navigation.selectedProjectID) { _, _ in
                            if let path = navigation.selectedProjectID.flatMap({ navigation.rememberedWorktrees[$0] }) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                    // LAYOUT-2.90: the banner slides over the top of the list
                    // below the persistent search row.
                    .overlay(alignment: .top) {
                        if let item = navigation.attentionBanner {
                            SidebarAttentionBanner(item: item, project: projects.first { $0.id == item.projectID },
                                projectIconData: projectIcons[item.projectID], onOpen: {
                                onNavigationIntent()
                                let visit = navigation.beginOpeningAttentionBanner(item, projects: projects, items: activity)
                                Task {
                                    let opened = await onOpenAttention(item)
                                    navigation.finishOpening(visit, succeeded: opened)
                                    if !opened { navigationError = "This target is unavailable or its request has changed." }
                                }
                            }, onDismiss: { navigation.dismissAttentionBanner(item) })
                            .padding(.horizontal, 6).padding(.top, 4)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .clipped()
                    .animation(.easeInOut(duration: reduceMotion ? 0 : 0.25), value: navigation.attentionBanner)
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
        // The search row shares the title-bar strip with the traffic lights
        // and the sidebar toggle, so the sidebar extends under the title bar
        // the same way the detail column does for the breadcrumb.
        .ignoresSafeArea(.container, edges: .top)
        }
        .task {
            while !Task.isCancelled {
                await refreshNavigation()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: reportController.activeID) { _, id in
            if id != nil {
                if frozenWorktreeOrder.isEmpty {
                    frozenWorktreeOrder = Dictionary(uniqueKeysWithValues: appState.repos.map { ($0.id, SidebarHostNavigation.displayedWorktrees(in: $0).map(\.id)) })
                    frozenPins = Dictionary(uniqueKeysWithValues: appState.repos.flatMap(\.worktrees).map { ($0.id, $0.isPinned) })
                    frozenRemoteRows = remoteMacsModel.worktreePanesByRemote
                }
            } else {
                frozenWorktreeOrder = [:]; frozenPins = [:]; frozenRemoteRows = [:]
            }
        }
        .onChange(of: navigation.selectedProjectID) { _, _ in reportController.close() }
        .onChange(of: navigation.query) { _, _ in reportController.close() }
        .onDisappear { reportController.close() }
        .onChange(of: appState.selectedWorktreePath) { old, new in
            rememberSelection(old)
            if let new,
               let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == new } }) {
                navigation.selectedProjectID = localProjectID(repo)
                navigation.rememberedWorktrees[localProjectID(repo)] = new
            }
        }
        .onRemoteWorktreeSelectionChange(identity: selectedRemoteIdentity, path: selectedRemoteWorktreePath) { _ in
            rememberRemoteSelection()
            if let identity = selectedRemoteIdentity, let path = selectedRemoteWorktreePath,
               let row = remoteMacsModel.worktreePanesByRemote[identity]?.first(where: { $0.path == path }) {
                navigation.selectedProjectID = SidebarProjection.projectID(row)
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
                onSubmit: { worktreeName, branch in
                    let err = await onAddWorktree(request.repo, worktreeName, branch)
                    if err == nil { pendingAddWorktree = nil }
                    return err
                },
                onCancel: { pendingAddWorktree = nil }
            )
        }
    }

    /// Clears the three traffic lights plus the sidebar-toggle button that
    /// macOS parks to their right in the title-bar strip.
    private static let searchRowLeadingInset: CGFloat = 112
    /// Fallback when the sidebar is not under a title bar.
    private static let searchRowMinimumHeight: CGFloat = 38
    /// Compact native toolbar viewers still hit-test through 40 points.
    private static let searchStripMinimumHeight: CGFloat = 40

    /// Search worktree identities and retained report content. It lives
    /// in the title-bar row beside the sidebar toggle, so the list starts
    /// directly below the toolbar instead of under a search row of its own.
    private func searchRow(height: CGFloat) -> some View {
        TextField("Find any project or worktree", text: $navigation.query)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .padding(.leading, Self.searchRowLeadingInset)
            .padding(.trailing, 10)
            .frame(height: height)
            .frame(minHeight: Self.searchStripMinimumHeight, alignment: .top)
    }

    private func voiceDictationButton(collapsed: Bool) -> some View {
        VoiceDictationButton(
            controller: voiceDictation,
            target: selectedVoicePaneID.flatMap { terminalManager.handle(for: $0) },
            collapsed: collapsed
        )
    }

    @ViewBuilder
    private func worktreeRows(section: SidebarWorktreeSection, activityCounts counts: SidebarActivityCounts) -> some View {
        if navigation.query.isEmpty {
            let filter = SidebarLayoutPolicy.projectFilter(selectedID: navigation.selectedProjectID, showsProjectRail: showsProjectRail)
            ForEach(orderedSidebarRepos.filter { filter == nil || localProjectID($0) == filter }) { repo in
                repoSection(repo, attentionCounts: counts, section: section)
            }
            remoteSection(projectFilter: filter, section: section)
        } else {
            remoteSection(projectFilter: nil, query: navigation.query)
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

    @ViewBuilder
    private func repoSection(_ repo: RepoEntry, attentionCounts: SidebarActivityCounts, section: SidebarWorktreeSection) -> some View {
        let forgeLink = forgeLink(for: repo)
        let resolvedDefaultBranch = remoteBranchStore.resolvedDefaultBranch(
            forRepoAt: repo.path,
            hint: repo.defaultBranchHint
        )
        let worktrees = displayedWorktrees(in: repo)
        let temporaryWorktrees = worktrees.filter { !SidebarHostNavigation.isPinned($0, in: repo) }
        let rows = Group {
            if section != .tasks {
                SidebarWorktreeSectionHeader("Pinned Agents", color: theme.sidebarDimIcon, isCollapsed: Binding(
                    get: { repo.isPinnedCollapsed },
                    set: { collapsed in
                        if let index = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                            appState.repos[index].isPinnedCollapsed = collapsed
                        }
                    }
                ), separatesPrecedingRows: false)
                .listRowInsets(EdgeInsets(top: 0, leading: showsProjectRail ? 0 : -20, bottom: 0, trailing: 0))
                .modifier(PinnedWorktreeDropTarget(repoID: repo.id, appState: $appState, isEnabled: navigation.query.isEmpty))
                if !repo.isPinnedCollapsed {
                    let members = worktrees.filter { SidebarHostNavigation.isPinned($0, in: repo) }
                    worktreeNodeRows(members, repo: repo, defaultBranch: resolvedDefaultBranch,
                                     attentionCounts: attentionCounts, isPinnedSection: true)
                    if members.isEmpty {
                        Text("Right-click a worktree to pin it here.")
                            .font(.caption)
                            .foregroundColor(theme.sidebarDimIcon)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }
                }
            }
            if section != .pinned {
                worktreeNodeRows(temporaryWorktrees,
                                 repo: repo, defaultBranch: resolvedDefaultBranch, attentionCounts: attentionCounts)
            }
        }
        if showsProjectRail {
            rows
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { !repo.isCollapsed },
                set: { expanded in
                    if let idx = appState.repos.firstIndex(where: { $0.id == repo.id }) {
                        appState.repos[idx].isCollapsed = !expanded
                    }
                }
            )) {
                rows
            } label: {
                HStack(spacing: 6) {
                    Text(repo.displayName).foregroundColor(theme.foreground).fontWeight(.semibold)
                    Spacer()
                    if SidebarMenuVisibility.showsAddWorktree(repo: repo) { addWorktreeButton(repo, showsLabel: false) }
                }
                .contextMenu {
                    if !repo.isGitTracked {
                        Button("Initialize Git Repository") { onInitializeGit(repo) }
                    }
                    if let forge = forgeLink {
                        Button(forge.menuTitle) { NSWorkspace.shared.open(forge.url) }
                    }
                    worktreeOrderPicker(repo)
                    Button("Remove Repository") { onRemoveRepo(repo) }
                }
            }
        }
    }

    private func worktreeNodeRows(_ worktrees: [WorktreeEntry], repo: RepoEntry, defaultBranch: String?,
                                  attentionCounts: SidebarActivityCounts, isPinnedSection: Bool = false) -> some View {
        let nodes = SidebarWorktreeHierarchy.nodes(for: worktrees, inRepoAtPath: repo.path, defaultBranch: defaultBranch)
        return ForEach(nodes) { node in
            SidebarWorktreeNodeRow(
                node: node, depth: 0, repositoryID: repo.id, expansion: $worktreeFolderExpansion,
                statsByWorktreePath: statsStore.stats, theme: theme,
                projectColumn: showsProjectRail, isPinnedSection: isPinnedSection
            ) { worktree, displayName in
                worktreeBlock(worktree, repo: repo, displayName: displayName, activityCounts: attentionCounts)
            }
            .modifier(SidebarWorktreeRowInsets(node: node, depth: 0, projectColumn: showsProjectRail))
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
           let project = projects.first(where: { $0.id == navigation.selectedProjectID && $0.isAvailable }) {
            let repo = appState.repos.first { localProjectID($0) == project.id }
            let canAdd = canAddWorktree(to: project)
            if repo != nil || canAdd {
                HStack {
                    if let repo {
                        SidebarWorktreeOrderControl(selection: Binding(
                            get: { appState.repos.first { $0.id == repo.id }?.worktreeOrderMode ?? .manual },
                            set: { setWorktreeOrderMode($0, for: repo) }
                        ), color: NSColor(theme.sidebarDimIcon))
                        .frame(width: 136, height: 28)
                    }
                    Spacer()
                    if canAdd {
                        Button(action: addWorktreeToSelectedProject) { Label("Add worktree", systemImage: "plus") }
                            .buttonStyle(.plain)
                            .help("Add worktree to \(project.name)")
                            .accessibilityLabel("Add worktree to \(project.name)")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.sidebarDimIcon)
                .padding(.horizontal, 6).frame(height: 44)
            }
        }
    }

    private func canAddWorktree(to project: SidebarProject) -> Bool {
        if let repo = appState.repos.first(where: { localProjectID($0) == project.id }) {
            return SidebarMenuVisibility.showsAddWorktree(repo: repo)
        }
        guard project.supportsWorktreeEditing == true,
              let ownerID = project.owner?.deviceID,
              let remoteMac = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == ownerID }) else { return false }
        return remoteMacsModel.repositoriesByRemote[RemoteMacIdentity(remoteMac)]?
            .contains(where: { $0.id == project.repositoryID }) == true
    }

    private func addWorktreeToSelectedProject() {
        guard navigation.query.isEmpty,
              let project = projects.first(where: { $0.id == navigation.selectedProjectID && $0.isAvailable }) else { return }

        if let repo = appState.repos.first(where: { localProjectID($0) == project.id }) {
            if SidebarMenuVisibility.showsAddWorktree(repo: repo) { presentAddWorktree(for: repo) }
            return
        }

        guard project.supportsWorktreeEditing == true,
              let ownerID = project.owner?.deviceID,
              let remoteMac = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == ownerID }),
              let repository = remoteMacsModel.repositoriesByRemote[RemoteMacIdentity(remoteMac)]?
                  .first(where: { $0.id == project.repositoryID }) else { return }
        onAddRemoteWorktree(remoteMac, repository)
    }

    /// Renders a worktree and its pane children as one visually-unified
    /// block. When the worktree is active, the whole block (worktree row +
    /// every pane row underneath) gets a single rounded highlight — the
    /// user can see at a glance which worktree they're "in" even when
    /// multiple panes are listed. Inside the highlighted block, the
    /// focused pane is distinguished by text emphasis rather than a
    /// second background.
    @ViewBuilder
    private func worktreeBlock(
        _ worktree: WorktreeEntry,
        repo: RepoEntry,
        displayName: String,
        activityCounts: SidebarActivityCounts
    ) -> some View {
        let isActive = appState.selectedWorktreePath == worktree.path && selectedRemoteIdentity == nil
        let attention = SidebarAttentionLayout.layout(for: worktree)
        let context = contextForLocalWorktree(worktree, repo: repo, displayName: displayName)
        let isDropTarget = dropTargetWorktreeID == worktree.id
        let groupsPanes = showsProjectRail && worktree.state == .running && !worktree.splitTree.allLeaves.isEmpty
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
            attentionStyle: attention.worktreeCapsule,
            attentionCount: worktree.state == .running && !worktree.splitTree.allLeaves.isEmpty ? 0 : activityCounts.attentionByWorktree[worktree.path, default: 0],
            project: project, projectIconData: iconStore.iconData(for: repo),
            identityMenu: worktree.path == repo.path ? nil : { anchor in
                WorktreeEmojiMenu.build(hasEmoji: worktree.emoji != nil,
                                        onChange: { editWorktreeEmoji(worktree, anchoredTo: anchor) },
                                        onClear: { SidebarHostNavigation.clearEmoji(worktreeID: worktree.id, in: &appState.repos) })
            },
            reportButton: SidebarReportButton(controller: reportController, context: context, theme: theme)
        )
        .frame(minHeight: showsProjectRail ? (groupsPanes ? 28 : 44) : 0)
        .overlay(alignment: .trailing) {
            SleepingWorktreeIndicator(state: terminalManager.worktreeSleepState, path: worktree.path)
        }
        .contentShape(Rectangle())
        let paneLeaves = worktree.state == .running ? worktree.splitTree.allLeaves : []
        let paneRow: (PaneSlotID) -> PaneTitleRow = { terminalID in
            let sessionName = worktree.paneSessions[terminalID]
                .map(ZmxLauncher.sessionName(for:))
            return PaneTitleRow(
                title: terminalManager.displayTitle(for: terminalID),
                isActiveWorktree: isActive,
                isFocusedPane: isActive
                    && worktree.focusedPaneSlotID == terminalID,
                isBusy: AgentLivenessMerge.isPaneBusy(
                    sessionName: sessionName,
                    liveness: claudeSessionRegistry.livenessBySession),
                theme: theme,
                // The pane-scoped capsule (agent-stop icon, or
                // notify/✓! text) renders directly; busy/idle no
                // longer feed it.
                attentionStyle: context.question != nil && context.questionPaneID == sessionName ? nil : attention.paneCapsules[terminalID],
                portBindings: portBindings.bindings[terminalID] ?? [],
                attentionCount: activityCounts.attentionByPane[sessionName ?? "", default: 0]
                    + (terminalID == worktree.splitTree.allLeaves.first ? activityCounts.unassignedAttentionByWorktree[worktree.path, default: 0] : 0)
            )
        }
        let panes = ForEach(paneLeaves, id: \.self) { terminalID in
            Button {
                onSelectPane(worktree.path, terminalID)
            } label: {
                paneRow(terminalID)
            }
            .buttonStyle(.plain)
            .transformAnchorPreference(key: WorktreeControlAnchors.self, value: .bounds) { $0[.pane(terminalID)] = $1 }
            // PWD-1.4: pane rows are drag sources. The payload
            // is a typed wrapper around the pane's UUID so
            // SwiftUI's Transferable matching keeps unrelated
            // drops from being mis-decoded as panes.
            .draggable(TransferablePaneSlotID(id: terminalID.id))
            .rightClickMenu {
                buildPaneMenu(terminalID: terminalID)
            }
            if let route = context.questionPaneID,
               worktree.paneSessions[terminalID].map(ZmxLauncher.sessionName(for:)) == route {
                SidebarWorktreeQuestion(context: context).padding(.leading, 33).padding(.trailing, 8)
            }
        }
        WorktreeBlock(
            worktree: worktree, repoID: repo.id, isActive: isActive, isDropTarget: isDropTarget,
            groupsPanes: groupsPanes, theme: theme, appState: $appState,
            reorderingEnabled: navigation.query.isEmpty,
            onSelect: { onSelect(worktree.path) },
            onMovePane: onMovePane,
            onPaneTargeted: { targeted in
                if targeted { dropTargetWorktreeID = worktree.id }
                else if dropTargetWorktreeID == worktree.id { dropTargetWorktreeID = nil }
            },
            menu: { anchor in buildWorktreeMenu(worktree, repo: repo, window: anchor.window) }
        ) {
            heading
        } panes: {
            panes
            if Self.showsWorktreeQuestion(questionPaneID: context.questionPaneID,
                                          displayedPaneSessions: paneLeaves.compactMap { worktree.paneSessions[$0].map(ZmxLauncher.sessionName(for:)) }) {
                SidebarWorktreeQuestion(context: context).padding(.leading, 33).padding(.trailing, 8)
            }
        }
    }

    static func showsWorktreeQuestion(questionPaneID: String?, displayedPaneSessions: [String]) -> Bool {
        guard let questionPaneID else { return true }
        return !displayedPaneSessions.contains(questionPaneID)
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
        // TEAM-7.2: team-aware items appear when the worktree is in a
        // team-enabled repo with ≥2 worktrees.
        if agentTeamsEnabled,
           let team = TeamView.team(for: worktree, in: appState.repos, teamsEnabled: true) {
            menu.addItem(.separator())
            // TEAM-7.2: opens the activity-log window for this team.
            let teamID = TeamLookup.id(of: team)
            let teamName = team.repoDisplayName
            let openWindow = self.openWindow
            menu.addItem(ClosureMenuItem(title: "Show Team Activity…") {
                openWindow(
                    id: TeamActivityLogWindowID.windowGroupID,
                    value: TeamActivityLogWindowID(teamID: teamID, teamName: teamName)
                )
            })
        }
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

    // MARK: Worktree order (LAYOUT-2.95)

    private func setWorktreeOrderMode(_ mode: WorktreeOrderMode, for repo: RepoEntry) {
        guard let index = appState.repos.firstIndex(where: { $0.id == repo.id }) else { return }
        appState.repos[index].worktreeOrderMode = mode
    }

    private static let worktreeOrderChoices = SidebarWorktreeOrderControl.choices

    private func worktreeOrderPicker(_ repo: RepoEntry) -> some View {
        Picker("Sort Worktrees", selection: Binding(
            get: { appState.repos.first { $0.id == repo.id }?.worktreeOrderMode ?? .manual },
            set: { setWorktreeOrderMode($0, for: repo) }
        )) {
            ForEach(Self.worktreeOrderChoices, id: \.mode) { Text($0.title).tag($0.mode) }
        }
    }

    private func worktreeOrderMenu(_ repo: RepoEntry) -> NSMenu {
        let menu = NSMenu()
        for choice in Self.worktreeOrderChoices {
            let item = ClosureMenuItem(title: choice.title) { setWorktreeOrderMode(choice.mode, for: repo) }
            item.state = repo.worktreeOrderMode == choice.mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Right-click below the last row in the project column.
    private func selectedProjectEmptySpaceMenu() -> NSMenu {
        let menu = NSMenu()
        guard navigation.query.isEmpty,
              let repo = appState.repos.first(where: { localProjectID($0) == navigation.selectedProjectID }) else { return menu }
        let sort = NSMenuItem(title: "Sort Worktrees", action: nil, keyEquivalent: "")
        sort.submenu = worktreeOrderMenu(repo)
        menu.addItem(sort)
        return menu
    }

    /// AppKit-side pane right-click menu (PWD-1.1 / PWD-1.3 / LAYOUT-2.7
    /// / TERM-8.10). The Move section is shared with the terminal-surface
    /// menu via `PaneMoveMenuBuilder`; the Copy-web-URL item is sidebar-
    /// only because the surface has no worktree-context-free way to know
    /// its session name without going through this same view tree.
    private func buildPaneMenu(terminalID: PaneSlotID) -> NSMenu {
        let menu = NSMenu()
        let defaultBranches = PaneMoveMenuContext.defaultBranches(
            for: appState.repos,
            using: remoteBranchStore
        )
        if let context = PaneMoveMenuContext.resolve(
            terminalID: terminalID,
            appState: appState,
            shellCwd: terminalManager.shellCwd(for: terminalID),
            defaultBranchesByRepoPath: defaultBranches
        ) {
            for item in PaneMoveMenuBuilder.items(
                terminalID: terminalID,
                context: context,
                onMove: onMovePane
            ) {
                menu.addItem(item)
            }
        }
        if case let .listening(_, port) = webController.status,
           let host = webController.serverHostname,
           let indices = appState.indicesOfWorktreeContaining(terminalID: terminalID),
           let sessionID = appState.repos[indices.repo].worktrees[indices.worktree].paneSessions[terminalID] {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Copy web URL") {
                Pasteboard.copy(WebURLComposer.url(
                    session: ZmxLauncher.sessionName(for: sessionID),
                    host: host,
                    port: port
                ))
            })
        }
        return menu
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
struct SidebarWorktreeRowInsets: ViewModifier {
    let node: SidebarWorktreeNode
    let depth: Int
    var projectColumn: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if projectColumn {
            content
        } else if SidebarWorktreeRowIndentation.shouldOutdent(node, depth: depth) {
            content.listRowInsets(
                EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0)
            )
        } else {
            content
        }
    }
}

/// Recursive row renderer with caller-owned disclosure state. `OutlineGroup`
/// owns its expansion state internally and starts folders collapsed; using
/// explicit `DisclosureGroup` bindings makes the initial state deterministic
/// and lets the folder label react to collapse by showing aggregate stats.
struct SidebarWorktreeNodeRow<WorktreeContent: View>: View {
    let node: SidebarWorktreeNode
    let depth: Int
    let repositoryID: UUID
    @Binding var expansion: SidebarWorktreeFolderExpansion
    let statsByWorktreePath: [String: WorktreeStats]
    let theme: GhosttyTheme
    var projectColumn: Bool = false
    var isPinnedSection: Bool = false
    let worktreeContent: (WorktreeEntry, String) -> WorktreeContent

    @ViewBuilder
    var body: some View {
        switch node {
        case .worktree(let worktree, let displayName):
            worktreeContent(worktree, displayName)

        case .folder(let path, let name, let children):
            let folderID = SidebarWorktreeFolderID(
                repositoryID: repositoryID,
                path: (isPinnedSection ? "pinned:" : "tasks:") + path
            )
            let isExpanded = expansion.isExpanded(folderID)
            let aggregate = SidebarWorktreeHierarchy.aggregateStats(
                in: node,
                statsByWorktreePath: statsByWorktreePath
            )
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expansion.isExpanded(folderID) },
                    set: { expansion.setExpanded($0, for: folderID) }
                )
            ) {
                ForEach(children) { child in
                    SidebarWorktreeNodeRow(
                        node: child,
                        depth: depth + 1,
                        repositoryID: repositoryID,
                        expansion: $expansion,
                        statsByWorktreePath: statsByWorktreePath,
                        theme: theme,
                        projectColumn: projectColumn,
                        isPinnedSection: isPinnedSection,
                        worktreeContent: worktreeContent
                    )
                    .modifier(SidebarWorktreeRowInsets(
                        node: child,
                        depth: depth + 1,
                        projectColumn: projectColumn
                    ))
                    .padding(.leading, projectColumn ? 16 : 0)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(theme.sidebarDimIcon)
                    Text(name)
                        .lineLimit(1)
                        .foregroundColor(theme.sidebarPrimaryText(isActive: false))
                    Spacer()
                    if !isExpanded {
                        WorktreeRowGutter(
                            stats: aggregate,
                            baseRef: nil,
                            theme: theme
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(minHeight: projectColumn ? 44 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
    }
}
