import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

/// @spec LAYOUT-2.62: When the project rail setting changes, the application shall place Add Repository beside Manage Remote Macs in the project footer if enabled, or retain the labeled Add Repository button in the single-sidebar footer if disabled.

/// @spec LAYOUT-2.64: When the pointer rests over a repository or remote Mac footer icon, the application shall display a tooltip describing the button's action.
struct SidebarView: View {
    @Binding var appState: AppState
    /// Used to read pane titles. Title change invalidation is deliberately
    /// scoped to `paneTitleInvalidations` below so MainWindow does not
    /// recompute on every shell title/PWD event.
    let terminalManager: TerminalManager
    @ObservedObject var paneTitleInvalidations: PaneTitleInvalidationSource
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
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onRemoveRepo: (RepoEntry) -> Void
    let onInitializeGit: (RepoEntry) -> Void
    let onStopWorktree: (String) -> Void
    let onDeleteWorktree: (String) -> Void
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

    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    @State private var navigation = SidebarNavigationState(prefix: "sidebar.mac")
    @ObservedObject private var iconStore = SidebarHostController.shared
    @ObservedObject private var worktreeIcons = WorktreeIconStore.shared
    @ObservedObject private var projectArtworkStyles = ProjectMapStyles.shared
    @AppStorage(SettingsKeys.worktreeArtworkEnabled) private var artworkEnabled = true
    @AppStorage(SettingsKeys.worktreeArtworkStyle) private var artworkStyle = "illustration"
    @State private var projects: [SidebarProject] = []
    @State private var remoteIcons: [String: Data] = [:]
    @State private var fetchedIconRevisions: [String: String] = [:]
    @State private var navigationError: String?
    @State private var showsRemoteManagement = false

    private var owner: WorktreeOrigin { iconStore.owner }
    private var worktreeArtworkRequests: [WorktreeArtworkRequest] {
        appState.repos.flatMap { repo in
            guard let project = projectArtworkSource(for: repo) else { return [WorktreeArtworkRequest]() }
            func flatten(_ nodes: [SidebarWorktreeNode], visible: Bool) -> [WorktreeArtworkRequest] {
                nodes.flatMap { node -> [WorktreeArtworkRequest] in
                    switch node {
                    case .worktree(let worktree, _):
                        guard var request = artworkRequest(for: worktree, repo: repo) else { return [] }
                        request.mapVisible = visible
                        return [request]
                    case .folder(let path, let name, let children):
                        let folder = WorktreeArtworkRequest(path: WorktreeMapLayout.folderPath(repo: repo.path, folder: path),
                            name: name, firstPaneSessionName: nil, project: project, mapHeight: 44,
                            mapVisible: visible, mapFolder: true)
                        let expanded = worktreeFolderExpansion.isExpanded(.init(repositoryID: repo.id, path: path))
                        return [folder] + flatten(children, visible: visible && expanded)
                    }
                }
            }
            return [WorktreeMapLayout.header(project: project)] + flatten(SidebarWorktreeHierarchy.nodes(for: repo.worktrees,
                inRepoAtPath: repo.path, defaultBranch: nil), visible: true) + [WorktreeMapLayout.footer(project: project)]
        }
    }
    private var mapHeaderRepo: RepoEntry? {
        guard artworkEnabled, showsProjectRail, !navigation.showsAttention, navigation.query.isEmpty else { return nil }
        return appState.repos.first { localProjectID($0) == navigation.selectedProjectID }
    }
    private func lastMapPath(in repo: RepoEntry) -> String? {
        if mapTailRepo?.id == repo.id, worktreeIcons.images[WorktreeMapLayout.footerPath(repo: repo.path)] != nil { return nil }
        return worktreeArtworkRequests.last {
            $0.project?.path == repo.path && $0.mapVisible && $0.path != WorktreeMapLayout.footerPath(repo: repo.path)
        }?.path
    }
    private var mapTailRepo: RepoEntry? {
        guard artworkEnabled, !navigation.showsAttention, navigation.query.isEmpty else { return nil }
        // The combined list has remote controls after its local repositories.
        // Only the selected-project column ends directly after its map.
        return mapHeaderRepo
    }
    private var mapTailBackground: AnyView {
        guard let repo = mapTailRepo,
              let image = worktreeIcons.images[WorktreeMapLayout.footerPath(repo: repo.path)] else { return AnyView(Color.clear) }
        return AnyView(WorktreeMapTailBackground(image: image, backgroundColor: theme.sidebarBackground))
    }
    private func artworkRequest(for worktree: WorktreeEntry, repo: RepoEntry) -> WorktreeArtworkRequest? {
        guard let project = projectArtworkSource(for: repo) else { return nil }
        let height = max(80, 44 + 20 * (worktree.state == .running ? worktree.splitTree.allLeaves.count : 0))
        if worktree.path == repo.path, worktree.state.hasOnDiskWorktree {
            return WorktreeArtworkRequest(path: worktree.path, name: "main", firstPaneSessionName: nil,
                project: project, isMainCheckout: true, mapHeight: Double(height))
        }
        var request = WorktreeIconStore.request(for: worktree, repoPath: repo.path, project: project)
        request?.mapHeight = Double(height)
        return request
    }
    private func projectArtworkSource(for repo: RepoEntry) -> ProjectArtworkSource? {
        guard var source = iconStore.artworkSource(for: repo) else { return nil }
        source.mapStyle = projectArtworkStyles.style(for: repo.path)
        return source
    }

    private func projectMapStyleMenu(_ repo: RepoEntry) -> some View {
        Menu("Map Style") {
            Picker("Map Style", selection: Binding<ProjectMapStyle?>(
                get: { projectArtworkStyles.override(for: repo.path) },
                set: { projectArtworkStyles.setOverride($0, for: repo.path) }
            )) {
                Text("Automatic (\(projectArtworkStyles.automaticStyle(for: repo.path).label))").tag(Optional<ProjectMapStyle>.none)
                ForEach(ProjectMapStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(Optional(style))
                }
            }
        }
    }
    private func localProjectID(_ repo: RepoEntry) -> String { "\(owner.deviceID.value):\(repo.id.uuidString)" }
    private var orderedSidebarRepos: [RepoEntry] {
        let positions = Dictionary(projects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        return appState.repos.enumerated().sorted {
            let left = positions[localProjectID($0.element), default: .max]
            let right = positions[localProjectID($1.element), default: .max]
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    private var activity: [SidebarActivityItem] {
        SidebarProjection.activity(sidebarLocalWorktrees(state: appState, owner: owner, titles: terminalManager.titles, liveness: claudeSessionRegistry.livenessBySession, prBadges: prStatusStore.infos.mapValues { PRBadge(from: $0) })
            + remoteMacsModel.promotedWorktreesForRelay())
    }
    private var projectIcons: [String: Data] {
        var result = remoteIcons
        for repo in appState.repos { result[localProjectID(repo)] = iconStore.icons[repo.id.uuidString] }
        return result
    }
    private func refreshNavigation() async {
        let remote = await remoteMacsModel.sidebarRelaySnapshot()
        let snapshot = iconStore.snapshot(state: &appState, owner: owner, remote: remote.projects,
            authoritativeRemoteOwners: remote.authoritativeOwnerIDs, savedRemoteOwners: Set(remoteMacsModel.savedRemoteMacs.map(\.id)))
        if projects != snapshot.projects { projects = snapshot.projects }
        navigation.reconcile(worktrees: sidebarLocalWorktrees(state: appState, owner: owner, titles: terminalManager.titles, liveness: claudeSessionRegistry.livenessBySession, prBadges: prStatusStore.infos.mapValues { PRBadge(from: $0) }) + remote.worktrees, projects: projects)
        if navigation.selectedProjectID == nil || !projects.contains(where: { $0.id == navigation.selectedProjectID }) {
            navigation.selectedProjectID = appState.repos.first(where: { repo in repo.worktrees.contains { $0.path == appState.selectedWorktreePath } }).map(localProjectID) ?? projects.first?.id
        }
        for project in remote.projects where project.isAvailable {
            if project.iconRevision == nil {
                remoteIcons[project.id] = nil
                fetchedIconRevisions[project.id] = nil
            }
            guard let revision = project.iconRevision, fetchedIconRevisions[project.id] != revision else { continue }
            if case .icon(let data) = await remoteMacsModel.sendRelayedWorktreeManagement(.projectIcon(repositoryID: project.repositoryID, revision: revision)) {
                remoteIcons[project.id] = data
                fetchedIconRevisions[project.id] = revision
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
        navigation.selectedProjectID = project.id; navigation.showsAttention = false; navigation.query = ""; navigationError = nil
        guard project.isAvailable else { navigationError = "The owning Mac is offline. Use Manage Remote Macs to reconnect."; return }
        if let index = appState.repos.firstIndex(where: { localProjectID($0) == project.id }) {
            appState.repos[index].isCollapsed = false
            let repo = appState.repos[index]
            let path = navigation.rememberedWorktrees[project.id].flatMap { saved in repo.worktrees.first { $0.path == saved }?.path } ?? repo.worktrees.first?.path
            if let path { onSelect(path) }
        } else if let mac = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == project.owner?.deviceID }) {
            let rows = (remoteMacsModel.worktreePanesByRemote[RemoteMacIdentity(mac)] ?? []).filter { SidebarProjection.projectID($0) == project.id }
            if let target = rows.first(where: { $0.path == navigation.rememberedWorktrees[project.id] }) ?? rows.first {
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
            projectMapStyleMenu(repo)
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
    private func remoteSection(projectFilter: String?, query: String = "") -> some View {
        RemoteMacsSection(model: remoteMacsModel, worktreePanesByRemote: remoteMacsModel.worktreePanesByRemote,
                          selectedRemoteIdentity: selectedRemoteIdentity, selectedRemoteWorktreePath: selectedRemoteWorktreePath,
                          selectedRemotePaneSessionName: selectedRemotePaneSessionName, theme: theme,
                          onSelectRemoteMac: onSelectRemoteMac, onSelectRemoteWorktree: onSelectRemoteWorktree,
                          onSelectRemotePane: onSelectRemotePane, onAddRemoteWorktree: onAddRemoteWorktree,
                          onDeleteRemoteWorktree: onDeleteRemoteWorktree, onAddRemoteMac: onAddRemoteMac,
                          projectFilter: projectFilter, query: query,
                          showsMacHierarchy: !showsProjectRail,
                          showsRepositoryHeaders: !showsProjectRail || !query.isEmpty,
                          editableProjectIDs: Set(projects.filter { $0.isAvailable && $0.supportsWorktreeEditing == true }.map(\.id)))
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
            RemoteMacConnectionsPopover(model: remoteMacsModel) {
                showsRemoteManagement = false
                onAddRemoteMac()
            }
        }
    }

    var body: some View {
        // Explicit dependency: the titles live on TerminalManager, while this
        // lightweight observable scopes invalidation to the sidebar.
        let _ = paneTitleInvalidations.generation
        let counts = SidebarActivityCounts(items: activity)
        HStack(spacing: 0) {
            if showsProjectRail {
                ProjectNavigationRail(projects: projects, counts: counts.attentionByProject, workingCounts: counts.workingByProject, icons: projectIcons,
                                      selectedID: navigation.selectedProjectID, showsAttention: navigation.showsAttention,
                                      collapsed: $navigation.railCollapsed, expandedWidth: $navigation.railExpandedWidth, selectionColor: theme.foreground.opacity(0.16), onSelect: selectProject,
                                      onAttention: { onNavigationIntent(); navigation.showsAttention = true; navigation.query = "" },
                                      onMove: moveProject, localDeviceID: owner.deviceID,
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
                if navigation.showsAttention {
                    SidebarAttentionList(navigation: navigation, items: activity, projects: projects,
                                         icons: projectIcons, selectionColor: theme.foreground.opacity(0.16),
                                         isCurrentWorktree: isCurrentAttentionWorktree) { item in
                        let opened = await onOpenAttention(item)
                        if !opened { navigationError = "This target is unavailable or its request has changed." }
                        return opened
                    }
                } else {
                    VStack(spacing: 0) {
                        if let repo = mapHeaderRepo,
                           let avatar = iconStore.artworkSource(for: repo)?.avatar,
                           let image = NSImage(data: avatar) {
                            HStack {
                                ProjectMapHeaderAvatar(image: image, backgroundColor: theme.sidebarBackground,
                                                       projectName: repo.displayName)
                                Spacer()
                            }.padding(.horizontal, 10).padding(.top, 6)
                        }
                        TextField("Find any project or worktree", text: $navigation.query,
                                  prompt: Text("Find any project or worktree").foregroundColor(theme.foreground.opacity(0.75)))
                            .textFieldStyle(.plain)
                            .foregroundColor(theme.foreground)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(theme.sidebarBackground.opacity(0.94), in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.foreground.opacity(0.2), lineWidth: 1) }
                            .padding(10)
                        if let repo = mapHeaderRepo, SidebarMenuVisibility.showsAddWorktree(repo: repo) {
                            HStack {
                                Spacer()
                                addWorktreeButton(repo, showsLabel: true,
                                    hasArtwork: worktreeIcons.images[WorktreeMapLayout.headerPath(repo: repo.path)] != nil)
                            }
                                .frame(height: 44).padding(.horizontal, 6)
                        }
                    }
                    .background {
                        if let repo = mapHeaderRepo,
                           let image = worktreeIcons.images[WorktreeMapLayout.headerPath(repo: repo.path)] {
                            WorktreeMapHeaderBackground(image: image, backgroundColor: theme.sidebarBackground)
                                .ignoresSafeArea(.container, edges: .top)
                        }
                    }
                    ScrollViewReader { proxy in
                        Group {
                            if showsProjectRail || artworkEnabled {
                                ProjectWorktreeColumn(rowSpacing: artworkEnabled ? 0 : 3, horizontalInset: artworkEnabled ? 0 : 6, emptySpaceBackground: mapTailBackground, onDoubleClickEmptySpace: addWorktreeToSelectedProject) {
                                    worktreeRows
                                }
                            }
                            else { List { worktreeRows }.listStyle(.sidebar) }
                        }
                        .onChange(of: navigation.selectedProjectID) { _, _ in
                            if let path = navigation.selectedProjectID.flatMap({ navigation.rememberedWorktrees[$0] }) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                }
                if !showsProjectRail {
                    Divider()
                    HStack {
                        Button(action: onAddRepo) { Label("Add Repository", systemImage: "plus") }
                        Spacer()
                        Button(navigation.showsAttention ? "Projects" : "Attention") {
                            onNavigationIntent(); navigation.showsAttention.toggle(); navigation.query = ""
                        }
                        remoteManagementButton
                    }.buttonStyle(.plain).font(.caption).padding(10)
                }
            }.frame(minWidth: 220, maxWidth: .infinity)
        }
        .background { if artworkEnabled { theme.sidebarBackground.ignoresSafeArea() } }
        .task {
            while !Task.isCancelled {
                await refreshNavigation()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: WorktreeArtworkTheme(theme: theme), initial: true) { _, artworkTheme in
            worktreeIcons.configure(theme: artworkTheme)
        }
        .onChange(of: appState.repos.map(\.path), initial: true) { _, paths in
            projectArtworkStyles.register(paths)
        }
        .onChange(of: worktreeArtworkRequests, initial: true) { _, requests in
            worktreeIcons.update(worktrees: requests, isActive: NSApplication.shared.isActive)
        }
        .onChange(of: artworkEnabled, initial: true) { _, enabled in
            worktreeIcons.configure(enabled: enabled, style: WorktreeArtworkStyle(rawValue: artworkStyle) ?? .illustration)
        }
        .onChange(of: artworkStyle) { _, style in
            worktreeIcons.configure(enabled: artworkEnabled, style: WorktreeArtworkStyle(rawValue: style) ?? .illustration)
        }
        .onChange(of: appState.selectedWorktreePath) { old, new in
            rememberSelection(old)
            if !navigation.showsAttention, let new,
               let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == new } }) {
                navigation.selectedProjectID = localProjectID(repo)
                navigation.rememberedWorktrees[localProjectID(repo)] = new
            }
        }
        .onRemoteWorktreeSelectionChange(identity: selectedRemoteIdentity, path: selectedRemoteWorktreePath) { _ in
            rememberRemoteSelection()
            if !navigation.showsAttention, let identity = selectedRemoteIdentity, let path = selectedRemoteWorktreePath,
               let row = remoteMacsModel.worktreePanesByRemote[identity]?.first(where: { $0.path == path }) {
                navigation.selectedProjectID = SidebarProjection.projectID(row)
            }
        }
        .onChange(of: showsProjectRail) { _, enabled in
            onNavigationIntent()
            navigation.showsAttention = false
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

    private func isCurrentAttentionWorktree(_ item: SidebarActivityItem) -> Bool {
        if let selectedRemoteIdentity {
            guard let route = remoteMacsModel.relayRouter.resolveWorktree(item.worktreeID) else { return false }
            return route.identity == selectedRemoteIdentity && route.path == selectedRemoteWorktreePath
        }
        return item.worktreeID == appState.selectedWorktreePath
    }

    @ViewBuilder
    private var worktreeRows: some View {
        let counts = SidebarActivityCounts(items: activity)
        if navigation.query.isEmpty {
            let filter = SidebarLayoutPolicy.projectFilter(selectedID: navigation.selectedProjectID, showsProjectRail: showsProjectRail)
            ForEach(orderedSidebarRepos.filter { filter == nil || localProjectID($0) == filter }) { repo in
                repoSection(repo, attentionCounts: counts)
            }
            remoteSection(projectFilter: filter)
        } else {
            remoteSection(projectFilter: nil, query: navigation.query)
            ForEach(appState.repos) { repo in
                let labels = SidebarWorktreeLabel.texts(for: repo.worktrees, inRepoAtPath: repo.path,
                    defaultBranch: remoteBranchStore.resolvedDefaultBranch(forRepoAt: repo.path, hint: repo.defaultBranchHint))
                ForEach(repo.worktrees.filter {
                    SidebarInteractionPolicy.matches(query: navigation.query, projectName: repo.displayName,
                        worktreeName: labels[$0.id] ?? $0.branch, branch: $0.branch)
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
    private func repoSection(_ repo: RepoEntry, attentionCounts: SidebarActivityCounts) -> some View {
        let forgeLink = forgeLink(for: repo)
        let resolvedDefaultBranch = remoteBranchStore.resolvedDefaultBranch(
            forRepoAt: repo.path,
            hint: repo.defaultBranchHint
        )
        let worktreeNodes = SidebarWorktreeHierarchy.nodes(
            for: repo.worktrees,
            inRepoAtPath: repo.path,
            defaultBranch: resolvedDefaultBranch
        )
        let rows = Group {
            ForEach(worktreeNodes) { node in
                SidebarWorktreeNodeRow(
                    node: node,
                    depth: 0,
                    repositoryID: repo.id,
                    expansion: $worktreeFolderExpansion,
                    statsByWorktreePath: statsStore.stats,
                    theme: theme,
                    projectColumn: showsProjectRail,
                    mapImages: artworkEnabled ? worktreeIcons.images : [:],
                    mapRepoPath: repo.path,
                    mapLastPath: lastMapPath(in: repo),
                    mapEnabled: artworkEnabled
                ) { worktree, displayName in
                    worktreeBlock(
                        worktree,
                        repo: repo,
                        displayName: displayName,
                        activityCounts: attentionCounts
                    )
                }
                .modifier(SidebarWorktreeRowInsets(node: node, depth: 0, projectColumn: showsProjectRail || artworkEnabled))
            }
        }
        if showsProjectRail {
            if mapHeaderRepo?.id != repo.id, SidebarMenuVisibility.showsAddWorktree(repo: repo) {
                HStack { Spacer(); addWorktreeButton(repo, showsLabel: true) }
                    .frame(height: 44)
            }
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
                if artworkEnabled {
                    VStack(spacing: 0) { rows }
                } else {
                    rows
                }
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
                    projectMapStyleMenu(repo)
                    Button("Remove Repository") { onRemoveRepo(repo) }
                }
            }
        }
    }

    private func addWorktreeButton(_ repo: RepoEntry, showsLabel: Bool, hasArtwork: Bool = false) -> some View {
        Button { presentAddWorktree(for: repo) } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                if showsLabel { Text("Add worktree") }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(hasArtwork ? .white.opacity(0.9) : theme.sidebarDimIcon)
            .frame(minWidth: 18, minHeight: 22).contentShape(Rectangle())
            .padding(.horizontal, hasArtwork ? 6 : 0)
            .background {
                if hasArtwork { RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.6)) }
            }
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
        let isDropTarget = dropTargetWorktreeID == worktree.id
        let groupsPanes = showsProjectRail && worktree.state == .running && !worktree.splitTree.allLeaves.isEmpty
        let generatedArtwork = artworkEnabled ? WorktreeArtworkBackground.resolveImage(
            isMainCheckout: worktree.path == repo.path,
            projectIcon: iconStore.icons[repo.id.uuidString],
            generated: worktreeIcons.images[worktree.path]
        ) : nil
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
            prBadge: prStatusStore.infos[worktree.path].map {
                PRBadge(
                    number: $0.number,
                    state: $0.state,
                    checks: $0.checks,
                    mergeable: $0.mergeable,
                    url: $0.url
                )
            },
            attentionStyle: attention.worktreeCapsule,
            attentionCount: worktree.state == .running && !worktree.splitTree.allLeaves.isEmpty ? 0 : activityCounts.attentionByWorktree[worktree.path, default: 0],
            hasArtwork: generatedArtwork != nil
        )
        .frame(minHeight: showsProjectRail ? (groupsPanes ? 28 : 44) : 0)
        .contentShape(Rectangle())
        let panes = Group {
            if worktree.state == .running {
                ForEach(worktree.splitTree.allLeaves, id: \.self) { terminalID in
                    let sessionName = worktree.paneSessions[terminalID]
                        .map(ZmxLauncher.sessionName(for:))
                    Button {
                        onSelectPane(worktree.path, terminalID)
                    } label: {
                        PaneTitleRow(
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
                            attentionStyle: attention.paneCapsules[terminalID],
                            portBindings: portBindings.bindings[terminalID] ?? [],
                            attentionCount: activityCounts.attentionByPane[sessionName ?? "", default: 0]
                                + (terminalID == worktree.splitTree.allLeaves.first ? activityCounts.unassignedAttentionByWorktree[worktree.path, default: 0] : 0),
                            hasArtwork: generatedArtwork != nil
                        )
                    }
                    .buttonStyle(.plain)
                    // PWD-1.4: pane rows are drag sources. The payload
                    // is a typed wrapper around the pane's UUID so
                    // SwiftUI's Transferable matching keeps unrelated
                    // drops from being mis-decoded as panes.
                    .draggable(TransferablePaneSlotID(id: terminalID.id))
                    .rightClickMenu {
                        buildPaneMenu(terminalID: terminalID)
                    }
                }
            }
        }
        let preview = AnyView(
            VStack(spacing: 0) {
                heading
                panes
            }
            .padding(.vertical, groupsPanes ? 8 : 0)
            .background { worktreeBackground(image: generatedArtwork, isActive: isActive, isRegenerating: worktreeIcons.regeneratingPaths.contains(worktree.path), fadesBottom: lastMapPath(in: repo) == worktree.path) }
            .background(theme.background, in: RoundedRectangle(cornerRadius: 6))
        )
        VStack(spacing: 0) {
            Button {
                onSelect(worktree.path)
            } label: {
                heading
            }
            .buttonStyle(.plain)
            .id(worktree.path)
            .worktreeReorderTarget(
                repoID: repo.id,
                worktreeID: worktree.id,
                appState: $appState, isEnabled: navigation.query.isEmpty,
                preview: preview,
                onMovePane: onMovePane,
                onPaneTargeted: { targeted in
                    if targeted { dropTargetWorktreeID = worktree.id }
                    else if dropTargetWorktreeID == worktree.id { dropTargetWorktreeID = nil }
                }
            )
            .rightClickMenu {
                buildWorktreeMenu(worktree, repo: repo)
            }

            panes
        }
        .padding(.vertical, groupsPanes ? 8 : 0)
        .frame(minHeight: generatedArtwork != nil ? artworkRequest(for: worktree, repo: repo)?.mapHeight ?? 80 : 0)
        .background { worktreeBackground(image: generatedArtwork, isActive: isActive, isRegenerating: worktreeIcons.regeneratingPaths.contains(worktree.path), fadesBottom: lastMapPath(in: repo) == worktree.path) }
        // PWD-1.5: drop-target highlight. Stroked so it composes with
        // the active-worktree background fill above when the dragged-
        // onto row is also the active one.
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.foreground.opacity(isDropTarget ? 0.5 : 0), lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func worktreeBackground(image: NSImage?, isActive: Bool, isRegenerating: Bool, fadesBottom: Bool) -> some View {
        let selectionColor = theme.foreground.opacity(isActive ? 0.16 : 0)
        if let image {
            WorktreeArtworkBackground(
                image: image,
                backgroundColor: theme.sidebarBackground,
                selectionColor: selectionColor,
                isRegenerating: isRegenerating,
                fadesBottom: fadesBottom,
                groupsText: true
            )
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selectionColor)
        }
    }

    /// Worktree row's right-click menu. Built as `NSMenu` (not a
    /// SwiftUI `.contextMenu`) for the List-row hoisting reason
    /// `.rightClickMenu` documents.
    private func worktreeNeighbor(_ worktree: WorktreeEntry, repo: RepoEntry, offset: Int) -> WorktreeEntry? {
        let parents = SidebarWorktreeHierarchy.parentFolderPaths(in: SidebarWorktreeHierarchy.nodes(for: repo.worktrees, inRepoAtPath: repo.path, defaultBranch: nil))
        let siblings = repo.worktrees.filter { parents[$0.id] == parents[worktree.id] }
        guard let index = siblings.firstIndex(where: { $0.id == worktree.id }), siblings.indices.contains(index + offset) else { return nil }
        let target = siblings[index + offset]
        var copy = appState
        return SidebarHostNavigation.moveWorktree(in: &copy, repositoryID: repo.path, worktreeID: worktree.path,
                                                  relativeTo: target.path, after: offset > 0) ? target : nil
    }

    private func buildWorktreeMenu(_ worktree: WorktreeEntry, repo: RepoEntry) -> NSMenu {
        let menu = NSMenu()
        // In-flight rows have nothing the menu actions can act on
        // safely — Open-in-Finder, Stop, and Delete-Worktree would all
        // either error or race the flow that owns the placeholder.
        if worktree.state.isInFlight {
            return menu
        }
        if navigation.query.isEmpty {
            for (title, offset) in [("Move Up", -1), ("Move Down", 1)] {
                if let target = worktreeNeighbor(worktree, repo: repo, offset: offset) {
                    menu.addItem(ClosureMenuItem(title: title) {
                        SidebarHostNavigation.moveWorktree(in: &appState, repositoryID: repo.path,
                                                           worktreeID: worktree.path, relativeTo: target.path, after: offset > 0)
                    })
                }
            }
        }
        if worktree.state != .stale {
            menu.addItem(ClosureMenuItem(title: "Open Worktree in Finder...") {
                NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path))
            })
            menu.addItem(.separator())
        }
        if artworkEnabled, let request = artworkRequest(for: worktree, repo: repo) {
            menu.addItem(ClosureMenuItem(title: "Regenerate Background Image") {
                worktreeIcons.regenerate(request)
            })
            menu.addItem(.separator())
        }
        if worktree.state == .running {
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
                onDeleteWorktree(worktree.path)
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
    var mapImages: [String: NSImage] = [:]
    var mapRepoPath = ""
    var mapLastPath: String?
    var mapEnabled = false
    let worktreeContent: (WorktreeEntry, String) -> WorktreeContent

    @ViewBuilder
    var body: some View {
        switch node {
        case .worktree(let worktree, let displayName):
            worktreeContent(worktree, displayName)
                .environment(\.worktreeMapIndent, mapEnabled ? CGFloat(depth * 12) : 0)

        case .folder(let path, let name, let children):
            let folderID = SidebarWorktreeFolderID(
                repositoryID: repositoryID,
                path: path
            )
            let isExpanded = expansion.isExpanded(folderID)
            let aggregate = SidebarWorktreeHierarchy.aggregateStats(
                in: node,
                statsByWorktreePath: statsByWorktreePath
            )
            if mapEnabled {
                VStack(spacing: 0) {
                    Button {
                        expansion.setExpanded(!isExpanded, for: folderID)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            Image(systemName: "folder")
                            Text(name).lineLimit(1)
                            Spacer()
                            if !isExpanded {
                                WorktreeRowGutter(stats: aggregate, baseRef: nil, theme: theme)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(mapImages[WorktreeMapLayout.folderPath(repo: mapRepoPath, folder: path)] == nil ? theme.foreground : .white)
                        .padding(.leading, CGFloat(8 + depth * 12)).padding(.trailing, 8)
                        .frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name), \(isExpanded ? "expanded" : "collapsed")")
                    .background {
                        let path = WorktreeMapLayout.folderPath(repo: mapRepoPath, folder: path)
                        if let image = mapImages[path] {
                            WorktreeArtworkBackground(image: image, backgroundColor: theme.sidebarBackground,
                                selectionColor: .clear, fadesBottom: mapLastPath == path, groupsText: true)
                        }
                    }
                    if isExpanded {
                        ForEach(children) { child in
                            SidebarWorktreeNodeRow(node: child, depth: depth + 1, repositoryID: repositoryID,
                                expansion: $expansion, statsByWorktreePath: statsByWorktreePath,
                                theme: theme, projectColumn: projectColumn, mapImages: mapImages,
                                mapRepoPath: mapRepoPath, mapLastPath: mapLastPath, mapEnabled: true,
                                worktreeContent: worktreeContent)
                        }
                    }
                }
            } else {
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
}
