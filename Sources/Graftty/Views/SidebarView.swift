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
    let appStateChanges: AppStateChanges
    let selectedRemoteIdentity: RemoteMacIdentity?
    let selectedRemoteWorktreePath: String?
    let selectedRemotePaneSessionName: String?
    let onSelect: (String) -> Void
    var onOpenAttention: (SidebarActivityItem) async -> Bool = { _ in false }
    var onNavigationIntent: () -> Void = {}
    let onSelectRemoteMac: (RemoteMac) -> Void
    let onSelectRemoteWorktree: (RemoteMac, String) -> Void
    let onWakeRemoteWorktree: (RemoteMac, String) -> Void
    let onAddRemoteWorktree: (RemoteMac, RemoteRepositoryInfo) -> Void
    /// Opens the sheet for a remote host from the Host row or Add worktree.
    let onAddRemoteWorktreeWithHost: (RemoteMac, RemoteRepositoryInfo, AddWorktreeHostContext?, String, String?) -> Void
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

    /// Injected by GrafttyApp so the terminal menu can gate "Copy web URL" on
    /// `controller.status == .listening` and read the address to compose it.
    @EnvironmentObject private var webController: WebServerController

    /// Injected by GrafttyApp so a local row's context can list the ports its
    /// panes' process subtrees are listening on.
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
    /// Keeps rows in their sections while a report is open.
    @State private var frozenActivity: [String: WorktreeActivitySections.Hold] = [:]
    /// The row last selected in each merged project. Paths alone can repeat across hosts.
    @State private var rememberedRowIDs: [String: String] = [:]
    @State private var collapsedMergedFolders: Set<String> = []
    @State private var rankRepairs = ProjectRankRepairTracker()
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
    /// Working agents per project. Waiting counts come from `SidebarWaitingCounts`.
    private func activityCounts(_ rows: [WorktreePanes]) -> SidebarActivityCounts {
        SidebarActivityCounts(items: SidebarProjection.activity(rows).filter(\.isBusy).map { item in
            var item = item
            item.occurrence = nil
            return item
        })
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
    private var mergedSidebar: SidebarMergedRows { makeMerged(local: localWorktrees) }

    private func makeMerged(local: [WorktreePanes]) -> SidebarMergedRows {
        let sleeping = remoteMacsModel.sleepingSnapshot()
        let known = Set(projects.map(\.id))
        let localID = owner.deviceID
        return SidebarMergedRows.make(projects: projects + sleeping.projects.filter { !known.contains($0.id) }, localRows: local,
            remoteRows: displayedRemoteRows.values.flatMap { $0 } + sleeping.rows, localDeviceID: localID,
            availability: { project in
                if project.owner?.deviceID == localID || project.isAvailable { return .reachable }
                return project.owner.map { sleeping.hostIDs.contains($0.deviceID) } == true ? .wakeable : .offline
            })
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
        // Git can hang, and this loop is what keeps the sidebar current. The
        // result arrives as a state change, which runs this again.
        Task { await iconStore.refreshOriginKeys(state: $appState) }
        var remote = await remoteMacsModel.sidebarRelaySnapshot(includeRelayed: true)
        remote.projects.removeAll { $0.owner?.deviceID == owner.deviceID }
        remote.worktrees.removeAll { $0.origin?.deviceID == owner.deviceID }
        let snapshot = iconStore.snapshot(state: $appState, owner: owner, remote: remote.projects,
            authoritativeRemoteOwners: remote.authoritativeOwnerIDs, savedRemoteOwners: Set(remoteMacsModel.savedRemoteMacs.map(\.id)).union(remote.projects.compactMap { $0.owner?.deviceID }))
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
        let shared = Set(merged.projects.filter(\.isOnSeveralHosts).compactMap(\.representative.originKey))
        if iconStore.multiHostOriginKeys != shared { iconStore.multiHostOriginKeys = shared }
        let next = selected ?? fallback
        if navigation.selectedProjectID != next { navigation.selectedProjectID = next }
        write(rankRepairs.due(ProjectMerge.repairs(merged.projects, isReachable: { $0.isAvailable && isReachable(host: $0.owner?.deviceID) })))
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
        // Choosing a project isn't reason enough to wake its hosts.
        guard let target = rows.first(where: { $0.id == rememberedRowIDs[project.id] }) ?? rows.first,
              target.availability != .wakeable else { return }
        openMergedRow(target)
    }
    private func openMergedRow(_ row: MergedWorktreeRow) {
        if row.hostID == owner.deviceID {
            if let index = appState.repos.firstIndex(where: { $0.worktrees.contains { $0.path == row.row.path } }) {
                appState.repos[index].isCollapsed = false
            }
            onSelect(row.row.path)
        } else if let mac = remoteMacsModel.remoteMac(delivering: row.row) {
            if row.availability == .wakeable { onWakeRemoteWorktree(mac, row.row.path) }
            else { onSelectRemoteWorktree(mac, row.row.path) }
        }
    }
    private func moveProject(_ id: String, _ target: String, _ after: Bool) {
        let merged = mergedSidebar
        let writes = merged.projectMove(id: id, target: target, after: after, changedAt: Date().timeIntervalSinceReferenceDate,
                                        isReachable: { $0.isAvailable && isReachable(host: $0.owner?.deviceID) })
        if !writes.isEmpty { write(writes); return }
        // Every host for this project is asleep, and the order has to be saved
        // somewhere. It only moves once a host has stored it.
        if let project = merged.project(id: id), project.availability == .wakeable,
           let member = project.members.first(where: { $0.id == lastUsedHost(project) }) ?? project.members.first(where: { $0.rank != nil }),
           let mac = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == member.owner?.deviceID }) {
            Task { @MainActor in
                do {
                    try await remoteMacsModel.wake(mac)
                    write(merged.projectMove(id: id, target: target, after: after, changedAt: Date().timeIntervalSinceReferenceDate,
                                             isReachable: { $0.id == member.id }))
                } catch { navigationError = "\(mac.label) didn't respond, so the project stayed in place." }
            }
            return
        }
        // No member stores ranks, so this is an older host: keep this device's order.
        guard var state = appState.sidebarNavigation,
              let source = merged.project(id: id)?.members.first?.id,
              let destination = merged.project(id: target)?.members.first?.id,
              state.order.move(source, relativeTo: destination, after: after) else { return }
        state.cachedProjects = state.order.sorted(state.cachedProjects)
        appState.sidebarNavigation = state; projects = state.cachedProjects
    }
    /// Pull and Remove act on one checkout, so each names its host when the
    /// project has several. Only this Mac's checkout can be removed from here.
    @ViewBuilder private func projectHostActions(_ project: SidebarProject, merged: SidebarMergedRows) -> some View {
        let mergedProject = merged.project(id: project.id)
        let several = mergedProject?.isOnSeveralHosts ?? false
        let repos = localRepos(in: mergedProject)
        // Two checkouts on this Mac are told apart by path.
        let label = { (repo: RepoEntry) in repos.count > 1 ? "This Mac · \(repo.path)" : "This Mac" }
        ForEach(repos) { repo in
            Button(SidebarMergedRows.pullTitle(hostLabel: label(repo), isOnSeveralHosts: several || repos.count > 1)) {
                Task { @MainActor in
                    if let error = await pullDefaultBranch(for: repo) { navigationError = error }
                }
            }
        }
        ForEach((mergedProject?.members ?? []).filter { $0.owner?.deviceID != owner.deviceID && merged.availability(ofMember: $0.id) != .offline }, id: \.id) { member in
            if let mac = remoteMacsModel.remoteMac(delivering: member) {
                Button(SidebarMergedRows.pullTitle(hostLabel: member.owner?.deviceLabel ?? mac.label, isOnSeveralHosts: several)) {
                    Task { @MainActor in
                        do {
                            // Waking also registers the route a sleeping host's row uses.
                            if mergedSidebar.availability(ofMember: member.id) == .wakeable { try await remoteMacsModel.wake(mac) }
                            guard let route = remoteMacsModel.relayRouter.resolveRepository(member.repositoryID) else {
                                throw RemoteMacsModel.ProjectControlError.unavailable
                            }
                            if case .error(_, let message, _, _) = await remoteMacsModel.pullDefaultBranch(on: mac, repositoryID: route.repositoryID) {
                                navigationError = message
                            }
                        } catch { navigationError = error.localizedDescription }
                    }
                }
            }
        }
        ForEach(repos) { repo in
            Button(SidebarMergedRows.removeTitle(hostLabel: label(repo), isOnSeveralHosts: several || repos.count > 1)) { onRemoveRepo(repo) }
        }
    }

    private func localRepos(in project: MergedProject?) -> [RepoEntry] {
        let members = Set(project?.members.map(\.id) ?? [])
        return appState.repos.filter { members.contains(localProjectID($0)) }
    }
    private func localRepo(in project: MergedProject?) -> RepoEntry? { localRepos(in: project).first }
    private func projectMenu(_ project: SidebarProject, merged: SidebarMergedRows) -> AnyView {
        guard let repo = localRepo(in: merged.project(id: project.id)) else { return AnyView(projectHostActions(project, merged: merged)) }
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
            projectHostActions(project, merged: merged)
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
        // One row only reads its own worktree, and every row builds this view.
        RemoteMacsSection(model: remoteMacsModel, expansion: $remoteSectionExpansion, worktreePanesByRemote: singleRow == nil ? displayedRemoteRows : [:],
                          selectedRemoteIdentity: selectedRemoteIdentity, selectedRemoteWorktreePath: selectedRemoteWorktreePath,
                          selectedRemotePaneSessionName: selectedRemotePaneSessionName, theme: theme,
                          onSelectRemoteMac: onSelectRemoteMac, onSelectRemoteWorktree: onSelectRemoteWorktree,
                          onAddRemoteWorktree: onAddRemoteWorktree,
                          onDeleteRemoteWorktree: onDeleteRemoteWorktree, onAddRemoteMac: onAddRemoteMac,
                          onSetupLinuxHost: onSetupLinuxHost,
                          projectFilter: projectFilter, query: query,
                          showsMacHierarchy: false,
                          showsRepositoryHeaders: !query.isEmpty,
                          editableProjectIDs: Set(projects.filter { $0.isAvailable && $0.supportsWorktreeEditing == true }.map(\.id)),
                          projects: projects, projectIcons: projectIcons, section: section, singleRow: singleRow,
                          reportController: reportController,
                          onDismissRequest: { navigation.dismissRequest(in: $0) },
                          contextForWorktree: { row in
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
        let promoted = remoteMacsModel.promotedWorktreesForRelay(includeRelayed: true).filter { $0.origin?.deviceID != owner.deviceID }
        let counts = activityCounts(local + promoted)
        let waiting = SidebarWaitingCounts.byProject(local + promoted) { navigation.worktreeContext($0) }
        let promotedContexts = relayedRowContexts(promoted)
        let merged = makeMerged(local: local)
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
                ProjectNavigationRail(projects: merged.projects.map(\.representative), counts: merged.rekeyed(waiting), workingCounts: merged.rekeyed(counts.workingByProject), icons: mergedProjectIcons(merged),
                                      selectedID: selectedMergedID,
                                      collapsed: $navigation.railCollapsed, expandedWidth: $navigation.railExpandedWidth, selectionColor: theme.foreground.opacity(0.16), onSelect: selectProject,

                                      onMove: moveProject, localDeviceID: owner.deviceID,
                                      aboveManagement: { AnyView(voiceDictationButton(collapsed: navigation.railCollapsed)) },
                                      management: { AnyView(HStack(spacing: 0) {
                                          addRepositoryIconButton
                                          remoteManagementButton
                                      }) }, menu: { projectMenu($0, merged: merged) })
                Divider()
            }
            VStack(spacing: 0) {
                if let navigationError {
                    Text(navigationError).font(.caption).foregroundStyle(.red).padding(8)
                }
                    ScrollViewReader { proxy in
                        SidebarWorktreeViewport {
                            // Without the rail, every project carries its own tiles in the list.
                            if navigation.query.isEmpty && showsProjectRail {
                                worktreeRows(section: .pinned, activityCounts: counts, remoteContexts: promotedContexts, merged: merged)
                                    .padding(.horizontal, 10)
                            }
                        } controls: {
                            if navigation.query.isEmpty && showsProjectRail {
                                selectedProjectAddWorktreeHeader(merged: merged)
                            }
                        } content: {
                            if showsProjectRail {
                                ProjectWorktreeColumn(onDoubleClickEmptySpace: addWorktreeToSelectedProject) {
                                    worktreeRows(section: .tasks, activityCounts: counts, remoteContexts: promotedContexts, merged: merged)
                                }
                            } else {
                                List { worktreeRows(section: .all, activityCounts: counts, remoteContexts: promotedContexts, merged: merged) }.listStyle(.sidebar)
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
                    frozenMergedOrder = mergedSidebar.temporaryOrder()
                    frozenActivity = Dictionary(uniqueKeysWithValues: mergedSidebar.projects.map { project in
                        let sections = mergedSidebar.sections(for: project.id)
                        return (project.id, WorktreeActivitySections.make(pinned: sections.pinned, temporary: sections.temporary,
                            context: { navigation.worktreeContext($0) }, holding: nil).hold)
                    })
                }
            } else {
                frozenWorktreeOrder = [:]; frozenPins = [:]; frozenRemoteRows = [:]; frozenMergedOrder = [:]; frozenActivity = [:]
            }
        }
        .onChange(of: navigation.selectedProjectID) { _, _ in reportController.close() }
        .onChange(of: navigation.query) { _, _ in reportController.close() }
        .onDisappear { reportController.close() }
        .onChange(of: appState.selectedWorktreePath) { old, new in
            rememberSelection(old)
            // STATE-2.13: leaving a worktree means its finished turn was seen.
            if let old, old != new { _ = appState.mutateWorktrees(atPath: old) { $0.leaveAttention() } }
            if let new,
               let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == new } }) {
                navigation.selectedProjectID = mergedSidebar.mergedID(forMember: localProjectID(repo))
                rememberSelection(new)
            }
        }
        .onRemoteWorktreeSelectionChange(identity: selectedRemoteIdentity, path: selectedRemoteWorktreePath) { previous, current in
            if let previous, let path = previous.worktreePath, previous != current,
               let mac = remoteMacsModel.savedRemoteMacs.first(where: { RemoteMacIdentity($0) == previous.identity }) {
                Task { await remoteMacsModel.acknowledgeLeftFinishedTurn(on: mac, worktreePath: path) }
            }
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
            // Every way in gets the Host row, including the menu command.
            let hostContext = request.hostContext ?? localHostContext(request.repo, merged: merged)
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
                    if err == nil {
                        hostContext?.onCreated()
                        pendingAddWorktree = nil
                    }
                    return err
                },
                onCancel: { pendingAddWorktree = nil },
                existingBranch: request.existingBranch,
                hostContext: hostContext
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
                }
                .contextMenu { projectMenu(project.representative, merged: merged) }
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
        let activity = WorktreeActivitySections.make(pinned: sections.pinned, temporary: sections.temporary,
            context: { navigation.worktreeContext($0) }, holding: frozenActivity[project.id],
            pullsWaitingPins: false).placed(in: section)
        if section != .tasks {
            pinnedTiles(activity.pinned, project: project, remoteContexts: remoteContexts)
            // Without the rail every project is listed, each with its own line (LAYOUT-2.227).
            if section == .all, let member = addWorktreeTarget(for: project, merged: merged),
               canAddWorktree(to: member, merged: merged) {
                newWorktreeLine(project.name) { presentAddWorktree(member: member, project: project) }
                    .disabled(localRepo(in: project) == nil && remoteProjectOperationInProgress)
                    .listRowInsets(EdgeInsets(top: 0, leading: -20, bottom: 0, trailing: 0))
            }
        }
        if section != .pinned {
            if !activity.needsYou.isEmpty {
                WorktreeListSectionTitle("Needs you", count: activity.needsYou.count, tone: .attention)
                ForEach(activity.needsYou) { row in
                    mergedRow(row, counts: counts, remoteContexts: remoteContexts)
                }
            }
            if !activity.working.isEmpty {
                WorktreeListSectionTitle("Working", count: activity.working.count, tone: .standard(theme.sidebarDimIcon))
                ForEach(activity.working) { row in
                    mergedRow(row, counts: counts, remoteContexts: remoteContexts)
                }
            }
            if !activity.recent.isEmpty {
                WorktreeListSectionTitle("Recent", tone: .standard(theme.sidebarDimIcon))
                ForEach(activity.recent) { row in
                    mergedRow(row, counts: counts, remoteContexts: remoteContexts)
                }
            }
            ForEach(merged.offlineHosts(for: project.id), id: \.self) { host in
                Text("\(host) is offline")
                    .font(.caption).italic()
                    .foregroundColor(theme.sidebarDimIcon)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// LAYOUT-2.113: a temporary row dropped on the grid's empty space pins it.
    @ViewBuilder
    private func pinnedTiles(_ rows: [MergedWorktreeRow], project: MergedProject,
                             remoteContexts: [String: SidebarWorktreeContext]) -> some View {
        let words = Dictionary(zip(rows.map(\.id), PinnedTile.words(for: rows.map {
            PinnedTile.Name(name: $0.relativeName, isMainCheckout: $0.row.isMainCheckout, branch: $0.row.displayBranch)
        })), uniquingKeysWith: { first, _ in first })
        let grid = PinnedTileGrid(rows: rows) { row in
            pinnedTile(row, word: words[row.id] ?? row.relativeName, remoteContexts: remoteContexts)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 0, leading: showsProjectRail ? 0 : -12, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        if let repo = localRepo(in: project) {
            grid.modifier(PinnedWorktreeDropTarget(repoID: repo.id, appState: $appState, isEnabled: navigation.query.isEmpty))
        } else {
            grid
        }
    }

    @ViewBuilder
    private func pinnedTile(_ row: MergedWorktreeRow, word: String, remoteContexts: [String: SidebarWorktreeContext]) -> some View {
        if row.hostID == owner.deviceID,
           let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == row.row.path } }),
           let worktree = displayedWorktrees(in: repo).first(where: { $0.path == row.row.path }) {
            localPinnedTile(worktree, repo: repo, row: row, word: word)
        } else if let mac = remoteMacsModel.remoteMac(delivering: row.row) {
            remoteSection(contexts: remoteContexts, projectFilter: nil, singleRow: .init(worktree: row.row, remoteMac: mac, displayName: row.relativeName,
                          hostLabel: row.hostLabel, isCached: row.availability == .wakeable, isTile: true, tileWord: word,
                          onOpen: { openMergedRow(row) },
                          onOpenPane: { context in Task { _ = await openReport(context) } },
                          onDrop: { drop, after in
                              handleRowDrop(drop, target: row.row.path, targetHost: mac.id, after: after)
                          }))
        } else {
            unreachablePinnedTile(row, word: word)
        }
    }

    /// A pinned agent this Mac can't route to right now keeps its place in the
    /// grid, drawn like a sleeping host's tile, instead of leaving an empty cell.
    private func unreachablePinnedTile(_ row: MergedWorktreeRow, word: String) -> some View {
        let projectID = SidebarProjection.projectID(row.row)
        let project = projects.first { $0.id == projectID }
            ?? SidebarProject(id: projectID, repositoryID: row.row.repositoryID ?? projectID, name: row.row.repoDisplayName)
        let host = row.hostLabel.isEmpty ? nil : row.hostLabel
        return PinnedTileFace(identity: row.row.iconIdentity, project: project, imageData: nil, word: word,
                              hostBadge: host, state: .asleep, isSelected: false,
                              fill: theme.foreground.opacity(0.07), selectedFill: theme.highlightedWorktreeBackground)
            .help(PinnedTile.hoverText(name: row.relativeName, host: host, status: .none) + "\nCan't be opened from this Mac right now")
            .pinnedTileAccessibility(name: row.relativeName, host: host, state: .asleep, isSelected: false) {}
    }

    private func localPinnedTile(_ worktree: WorktreeEntry, repo: RepoEntry, row: MergedWorktreeRow, word: String) -> some View {
        let isActive = appState.selectedWorktreePath == worktree.path && selectedRemoteIdentity == nil
        let context = contextForLocalWorktree(worktree, repo: repo, displayName: row.relativeName)
        let status = SidebarRowStatus.resolve(context: context, worktree: context.worktree, isCached: false)
        let state = PinnedTileState.resolve(status: status, isCached: false)
        let isMain = worktree.path == repo.path
        let projectID = localProjectID(repo)
        let project = projects.first { $0.id == projectID }
            ?? SidebarProject(id: projectID, repositoryID: repo.id.uuidString, name: repo.displayName)
        let select = { onSelect(worktree.path) }
        return PinnedTileFace(identity: context.worktree.iconIdentity, project: project,
                              imageData: isMain ? iconStore.iconData(for: repo) : iconStore.drawingData(for: worktree),
                              word: word,
                              hostBadge: nil, state: state, isSelected: isActive,
                              fill: theme.foreground.opacity(0.07), selectedFill: theme.highlightedWorktreeBackground)
            .rightClickMenu(anchored: { anchor in buildWorktreeMenu(worktree, repo: repo, context: context, window: anchor.window) })
            .overlay {
                WorktreeDragSourceOverlay(
                    payload: WorktreeReorderTarget.canDrag(worktree, in: repo, isEnabled: navigation.query.isEmpty)
                        ? TransferableWorktreeMove(repoID: repo.id, worktreeID: worktree.id) : nil,
                    onClick: select)
            }
            .modifier(PinnedTileDropTarget(isEnabled: navigation.query.isEmpty && !worktree.state.isInFlight) { drop, after in
                if handleRowDrop(drop, target: worktree.path, targetHost: owner.deviceID, after: after) { return true }
                return drop.apply(repoID: repo.id, targetWorktreeID: worktree.id, placement: after ? .after : .before,
                                  allowsReordering: true, to: &appState) != .rejected
            })
            .modifier(PinnedTileHoverCard(name: row.relativeName, host: nil, status: status))
            .pinnedTileAccessibility(name: row.relativeName, host: nil, state: state, isSelected: isActive, open: select)
    }

    /// LAYOUT-2.227: where a new worktree starts, directly under the tiles.
    private func newWorktreeLine(_ projectName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 18)
                Text("New worktree").font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.sidebarSecondaryText)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New worktree in \(projectName)")
        .accessibilityLabel("New worktree in \(projectName)")
    }

    /// One row, drawn by whichever view owns its data: local rows read live
    /// terminal state, remote rows read their host's report.
    @ViewBuilder
    private func mergedRow(_ row: MergedWorktreeRow, counts: SidebarActivityCounts,
                           remoteContexts: [String: SidebarWorktreeContext]) -> some View {
        if row.hostID == owner.deviceID,
           let repo = appState.repos.first(where: { $0.worktrees.contains { $0.path == row.row.path } }),
           let worktree = displayedWorktrees(in: repo).first(where: { $0.path == row.row.path }) {
            worktreeBlock(worktree, repo: repo, displayName: row.relativeName, activityCounts: counts,
                          hostLabel: SidebarMergedRows.hostText(row, isLocal: true))
                .modifier(MergedRowInsets(projectColumn: showsProjectRail))
        } else if let mac = remoteMacsModel.remoteMac(delivering: row.row) {
            remoteSection(contexts: remoteContexts, projectFilter: nil, singleRow: .init(worktree: row.row, remoteMac: mac, displayName: row.relativeName,
                          hostLabel: SidebarMergedRows.hostText(row, isLocal: false), isCached: row.availability == .wakeable,
                          onOpen: { openMergedRow(row) },
                          onOpenPane: { context in Task { _ = await openReport(context) } },
                          onDrop: { drop, after in
                              handleRowDrop(drop, target: row.row.path, targetHost: mac.id, after: after)
                          }))
                .modifier(MergedRowInsets(projectColumn: showsProjectRail))
        }
    }

    /// Pinned rows take their order from ranks. Returns false for a drop this
    /// doesn't own, such as pinning a temporary row.
    private func handleRowDrop(_ drop: WorktreeRowDrop, target: String, targetHost: RemoteDeviceID, after: Bool) -> Bool {
        let merged = mergedSidebar
        // Not the selected project: without the rail, every project is on screen.
        guard let projectID = merged.projectID(holdingRowAt: target, on: targetHost) else { return false }
        let rows = merged.flattenedRows(for: projectID)
        guard let targetRow = rows.first(where: { $0.hostID == targetHost && $0.row.path == target }) else { return false }
        let sourceRow: MergedWorktreeRow?
        switch drop {
        case .worktree(let payload):
            let path = appState.repos.first { $0.id == payload.repoID }?.worktrees.first { $0.id == payload.worktreeID }?.path
            sourceRow = rows.first { $0.hostID == owner.deviceID && $0.row.path == path }
        case .remote(let payload):
            sourceRow = rows.first { $0.hostID == payload.deviceID && $0.row.path == payload.path }
        }
        // A temporary row dropped here pins it: the local path owns that.
        guard let sourceRow, sourceRow.row.sidebar?.isPinned == true else { return false }
        guard let move = merged.pinnedMove(source: sourceRow.id, target: targetRow.id, after: after, projectID: projectID,
                                           isWritable: { row in
                                               row.row.sidebar?.pinnedRank != nil && (isReachable(host: row.hostID) || row.id == sourceRow.id)
                                           }) else { return true }
        apply(move)
        return true
    }

    private func isReachable(host: RemoteDeviceID?) -> Bool {
        host == owner.deviceID || remoteMacsModel.savedRemoteMacs.contains {
            let identity = RemoteMacIdentity($0)
            return remoteMacsModel.connectionState(for: identity) == .connected
                && ($0.id == host || (remoteMacsModel.paneFeedFailure(for: identity) == nil
                    && remoteMacsModel.worktreePanesByRemote[identity]?.contains(where: { $0.origin?.deviceID == host }) == true))
        }
    }

    private func apply(_ move: SidebarMergedRows.PinnedMove) {
        switch move {
        case .legacy(let source, let target, let after):
            guard let mac = remoteMacsModel.remoteMac(delivering: source.row) else { return }
            Task { @MainActor in
                do {
                    if source.availability == .wakeable { try await remoteMacsModel.wake(mac) }
                    try await remoteMacsModel.moveWorktree(source.row, relativeTo: target.row, after: after, on: mac)
                } catch { navigationError = error.localizedDescription }
            }
        case .ranks(let writes):
            for write in writes {
                if write.row.hostID == owner.deviceID, let repositoryID = write.row.row.repositoryID {
                    SidebarHostNavigation.setPinnedRank(write.rank, worktreeID: write.row.row.path, repositoryID: repositoryID, in: &appState)
                } else if let mac = remoteMacsModel.remoteMac(delivering: write.row.row) {
                    Task { @MainActor in
                        do {
                            // Moving a sleeping host's row needs that host, so it wakes.
                            if write.row.availability == .wakeable { try await remoteMacsModel.wake(mac) }
                            try await remoteMacsModel.setPinnedRank(write.rank, worktree: write.row.row, on: mac)
                        } catch { navigationError = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func write(_ writes: [(member: SidebarProject, rank: String, changedAt: Double)]) {
        for write in writes {
            if write.member.owner?.deviceID == owner.deviceID {
                SidebarHostNavigation.setProjectRank(write.rank, changedAt: write.changedAt, repositoryID: write.member.repositoryID, in: &appState)
            } else {
                Task { @MainActor in
                    do { try await remoteMacsModel.setProjectRank(write.rank, changedAt: write.changedAt, for: write.member) }
                    catch { navigationError = error.localizedDescription }
                }
            }
        }
    }

    private func presentAddWorktree(for repo: RepoEntry) {
        remoteBranchStore.pulse()
        prStatusStore.pulse()
        pendingAddWorktree = AddWorktreeRequest(repo: repo, prefill: "")
    }

    @ViewBuilder
    private func selectedProjectAddWorktreeHeader(merged: SidebarMergedRows) -> some View {
        if navigation.query.isEmpty,
           let project = addWorktreeTarget(in: merged),
           canAddWorktree(to: project, merged: merged) {
            let repo = appState.repos.first { localProjectID($0) == project.id }
            VStack(spacing: 0) {
                Divider().padding(.horizontal, 10)
                newWorktreeLine(merged.project(id: merged.mergedID(forMember: project.id))?.name ?? project.name,
                                action: addWorktreeToSelectedProject)
                    .disabled(repo == nil && remoteProjectOperationInProgress)
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
        }
    }

    /// The checkout Add worktree targets in the selected project.
    private func addWorktreeTarget(in merged: SidebarMergedRows) -> SidebarProject? {
        merged.project(id: merged.selectedProjectID(for: navigation.selectedProjectID)).flatMap { addWorktreeTarget(for: $0, merged: merged) }
    }

    private func addWorktreeTarget(for project: MergedProject, merged: SidebarMergedRows) -> SidebarProject? {
        guard let choice = AddWorktreeHostChoice.defaultChoice(addWorktreeChoices(project, merged: merged), lastUsedID: lastUsedHost(project))?.choice else { return nil }
        return project.members.first { $0.id == choice.id }
    }

    private func lastUsedHost(_ project: MergedProject) -> String? {
        UserDefaults.standard.string(forKey: "addWorktree.lastHost.\(project.id)")
    }

    private func addWorktreeChoices(_ project: MergedProject, merged: SidebarMergedRows) -> [AddWorktreeHostChoice] {
        AddWorktreeHostChoice.labeled(project.members.filter { $0.supportsWorktreeEditing == true || $0.owner?.deviceID == owner.deviceID }.map { member in
            let isLocal = member.owner?.deviceID == owner.deviceID
            return AddWorktreeHostChoice(
                id: member.id,
                host: isLocal ? "This Mac" : member.owner?.deviceLabel ?? member.name,
                path: isLocal ? member.repositoryID : remoteMacsModel.relayRouter.resolveRepository(member.repositoryID)?.repositoryID,
                availability: merged.availability(ofMember: member.id))
        })
    }

    /// The Host row, for a project with more than one checkout to choose from.
    private func hostContext(member: SidebarProject, project: MergedProject, merged: SidebarMergedRows) -> AddWorktreeHostContext? {
        let choices = addWorktreeChoices(project, merged: merged)
        guard choices.count > 1 else { return nil }
        return AddWorktreeHostContext(projectName: project.name, choices: choices, selectedID: member.id, onSelect: { id, name, branch in
            guard let next = project.members.first(where: { $0.id == id }) else { return }
            pendingAddWorktree = nil
            // Local and remote sheets have separate presenters, and one can't
            // appear while the other is still dismissing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                presentAddWorktree(member: next, project: project, name: name, branch: branch)
            }
        }, onCreated: {
            UserDefaults.standard.set(member.id, forKey: "addWorktree.lastHost.\(project.id)")
        })
    }

    private func localHostContext(_ repo: RepoEntry, merged: SidebarMergedRows) -> AddWorktreeHostContext? {
        let id = localProjectID(repo)
        guard let project = merged.project(id: merged.mergedID(forMember: id)),
              let member = project.members.first(where: { $0.id == id }) else { return nil }
        return hostContext(member: member, project: project, merged: merged)
    }

    /// Opens Add Worktree on one host. A project on several hosts gets a Host row.
    private func presentAddWorktree(member: SidebarProject, project: MergedProject, name: String = "", branch: String? = nil) {
        let context = hostContext(member: member, project: project, merged: mergedSidebar)
        if let repo = appState.repos.first(where: { localProjectID($0) == member.id }) {
            guard SidebarMenuVisibility.showsAddWorktree(repo: repo) else { return }
            remoteBranchStore.pulse()
            prStatusStore.pulse()
            pendingAddWorktree = AddWorktreeRequest(repo: repo, prefill: name, existingBranch: branch, hostContext: context)
            return
        }
        guard !remoteProjectOperationInProgress else { return }
        remoteProjectOperationInProgress = true
        navigationError = nil
        Task { @MainActor in
            defer { remoteProjectOperationInProgress = false }
            do {
                // Choosing a sleeping host wakes it to load its branches.
                if mergedSidebar.availability(ofMember: member.id) == .wakeable,
                   let sleeping = remoteMacsModel.savedRemoteMacs.first(where: { $0.id == member.owner?.deviceID }) {
                    try await remoteMacsModel.wake(sleeping)
                }
                var target = member
                target.isAvailable = true
                let (mac, repository) = try await remoteMacsModel.addWorktreeRepository(for: target)
                onAddRemoteWorktreeWithHost(mac, repository, context, name, branch)
            } catch { navigationError = error.localizedDescription }
        }
    }

    private func canAddWorktree(to project: SidebarProject, merged: SidebarMergedRows) -> Bool {
        if let repo = appState.repos.first(where: { localProjectID($0) == project.id }) {
            return SidebarMenuVisibility.showsAddWorktree(repo: repo)
        }
        // Opening the sheet wakes a sleeping host to load its branches.
        if merged.availability(ofMember: project.id) == .wakeable { return project.supportsWorktreeEditing == true }
        return remoteMacsModel.editableRepositoryTarget(for: project) != nil
    }

    private func addWorktreeToSelectedProject() {
        let merged = mergedSidebar
        guard navigation.query.isEmpty, let member = addWorktreeTarget(in: merged),
              let project = merged.project(id: merged.mergedID(forMember: member.id)) else { return }
        presentAddWorktree(member: member, project: project)
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
        let status = SidebarRowStatus.resolve(context: context, worktree: context.worktree, isCached: false)
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
            hostLabel: hostLabel,
            onRemove: { window in onDeleteWorktree(worktree.path, window) }
        )
        let headingView = heading
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
            menu: { anchor in buildWorktreeMenu(worktree, repo: repo, context: context, window: anchor.window) },
            onDrop: { drop, placement in
                handleRowDrop(drop, target: worktree.path, targetHost: owner.deviceID, after: placement == .after)
            }
        ) {
            WorktreeRowIdentitySlot(entry: worktree, displayName: displayName, isMainCheckout: worktree.path == repo.path, theme: theme,
                prBadge: prBadge, status: status, project: project, projectIconData: iconStore.iconData(for: repo),
                drawingData: iconStore.drawingData(for: worktree),
                identityMenu: worktree.path == repo.path ? nil : { anchor in
                    WorktreeEmojiMenu.build(hasEmoji: worktree.emoji != nil,
                                            onChange: { editWorktreeEmoji(worktree, anchoredTo: anchor) },
                                            onClear: { SidebarHostNavigation.clearEmoji(worktreeID: worktree.id, in: &appState.repos) })
                })
        } heading: {
            headingView
        } status: {
            let target = SidebarWorktreeStatusTarget(status: status, secondary: theme.sidebarSecondaryText) {
                Task { _ = await openReport(context) }
            }
            // An empty stack would still occupy a slot in the block, so only a
            // divergence brings one.
            if let divergence = heading.statusLineDivergence {
                // DIVERGE-1.1: the status line truncates before the divergence.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    target.frame(maxWidth: .infinity, alignment: .leading)
                    divergence.padding(.trailing, 8)
                }
            } else {
                target
            }
        }
    }

    /// Worktree row's right-click menu. Built as `NSMenu` (not a
    /// SwiftUI `.contextMenu`) for the List-row hoisting reason
    /// `.rightClickMenu` documents. Reordering is drag-only and the
    /// emoji identity has its own menu on the identity slot
    /// (LAYOUT-2.96), so neither appears here.
    private func buildWorktreeMenu(_ worktree: WorktreeEntry, repo: RepoEntry, context: SidebarWorktreeContext,
                                   window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        SidebarAttentionDismissalMenu.add(to: menu, context: context) { context in
            navigation.dismissRequest(in: context)
            SidebarAttentionDismissalMenu.acknowledge(
                SidebarAttentionDismissal.requests(for: context, supportsExactAcknowledgement: true), in: &appState)
        }
        // In-flight rows have nothing the menu actions can act on
        // safely — Open-in-Finder, Stop, and Delete-Worktree would all
        // either error or race the flow that owns the placeholder.
        if worktree.state.isInFlight {
            return menu.droppingTrailingSeparator()
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


    /// The terminal menu's Copy web URL (LAYOUT-2.7): the surface has no way to
    /// know its session name without the repositories this view holds.
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
        perform action: @escaping (_ previous: RemoteMacSidebarSelection?, _ current: RemoteMacSidebarSelection?) -> Void
    ) -> some View {
        let selection = identity.map {
            RemoteMacSidebarSelection(identity: $0, worktreePath: path)
        }
        return onChange(of: selection) { previous, current in action(previous, current) }
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
