#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI

struct SidebarWorktreeViewportRow: Equatable {
    var id: String
    var minY: CGFloat
    var maxY: CGFloat
    var projectID: String? = nil

    static func topVisible(in rows: [Self]) -> String? {
        rows.filter { $0.maxY > 0 }.min { $0.minY < $1.minY }?.id
    }
}

private struct SidebarWorktreeViewportPreference: PreferenceKey {
    static let defaultValue: [SidebarWorktreeViewportRow] = []
    static func reduce(value: inout [SidebarWorktreeViewportRow], nextValue: () -> [SidebarWorktreeViewportRow]) {
        value.append(contentsOf: nextValue())
    }
}

public struct WorktreeListContent: View {
    public static let iPadRowTrailingInset: CGFloat = 2
    static let iPadRowLeadingInset: CGFloat = 10

    @State private var state: LoadState = .loading
    @State private var loadingStage: RemoteWorktreeLoadStage = .connecting
    @State private var isAddSheetPresented: Bool = false
    @State private var showsRemoteMacManagement = false
    @State private var pendingDelete: PendingDelete?
    @State private var pendingForceDelete: PendingForceDelete?
    @State private var errorToast: String?
    @State private var errorToastTask: Task<Void, Never>?
    @State private var refreshError: String?
    @State private var openingWorktrees: Set<OpeningWorktreeKey> = []
    @State private var selectionIntentGeneration: UInt64 = 0
    @State private var worktreeCreation = MobileWorktreeCreation()
    @State private var loadedHostID: UUID?
    @State private var presentedHostID: UUID?
    /// Counts applied pushed frames. A pull whose count changed while it was
    /// in flight is dropped in favour of the pushed rows (IOS-4.54); this can
    /// also drop a pull that read a newer frame, which the stream then delivers.
    @State private var appliedPushCount: UInt64 = 0
    @State private var remoteMacConnections: [RemoteMacConnectionSummary] = []
    @State private var reconnectingRemoteMacIDs:
        Set<RemoteMacConnectionSummary.ID> = []

    @Bindable private var navigation: SidebarNavigationState
    @State private var sidebarSnapshot: SidebarSnapshot?
    @State private var projectIconCache = ProjectIconCache()
    private var projectIcons: [String: Data] { projectIconCache.icons }
    @State private var listEditMode: EditMode = .inactive
    @State private var reportWorktreeID: String?
    @State private var reportOrder: SidebarWorktreeReportOrder?
    @State private var orderMutationID: UUID?
    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    @State private var worktreeScrollSpace = UUID()
    @State private var restoringWorktreeScroll = false
    @State private var restoredWorktreeProjectID: String?
    private var orderMutationInFlight: Bool { orderMutationID != nil }
    // NavigationSplitView gives its narrow sidebar a compact size class even
    // when RootView chose the iPad layout. Follow the navigation container.
    private let isSidebar: Bool
    private var remoteSidebarProvider: (@MainActor ([WorktreePanes]) async -> PanesStateMessage?)?
    private var remoteUpdatesProvider: (@MainActor () -> AsyncStream<RemoteWorktreeUpdate>?)?
    private var navigationWindowWidth: Double

    private struct PendingDelete: Identifiable, Equatable {
        let id = UUID()
        let worktree: WorktreePanes
        let action: WorktreePickerSwipeAction
    }

    private struct DeleteRequestContext {
        let hostID: UUID
        let remoteConnectionProvider: RemoteConnectionProvider?
    }

    private struct PendingForceDelete: Identifiable {
        let id = UUID()
        let worktreePath: String
        let stderr: String
        let shortStatus: String
        let requestContext: DeleteRequestContext
    }

    private struct OpeningWorktreeKey: Hashable {
        let hostID: UUID
        let path: String
    }

    public let host: Host
    /// A compact navigation destination, independent of shared sidebar selection.
    let project: SidebarProject?
    /// Ghostty palette for theming row text. nil keeps the system colors
    /// in use on the compact (iPhone) path, where the List renders against
    /// the standard grouped-list background; the iPad sidebar paints a
    /// themed background so it supplies a non-nil theme here.
    public let theme: GhosttyThemeColors?
    /// Path of the currently-active worktree (iPad: `appState
    /// .selectedWorktreePath`). When non-nil, the matching worktree
    /// block renders with the active highlight (IPAD-1.16) and its
    /// pane rows pick the active-worktree brightness bucket.
    public let selectedWorktreePath: String?
    /// Session name of the focused pane (iPad: `appState.focusedPaneId`).
    /// When set, the matching pane row uses the brightest focused
    /// bucket via `theme.paneTitle(isFocusedPane: true, …)`.
    public let focusedPaneId: String?
    public let includeRemoteWorktrees: Bool
    /// Initial authenticated loading is deferred until the scene is active
    /// and the biometric connection gate is open. Keying the load task on
    /// this value makes unlock trigger the first fetch automatically instead
    /// of leaving the failed pre-unlock attempt behind a Refresh button.
    public let isReadyToLoad: Bool
    public let remoteConnectionProvider: RemoteConnectionProvider?
    public let remoteSnapshotProvider: RemoteWorktreeSnapshotProvider?
    public let onSelect: (WorktreePanes) -> Void
    public let onSelectPane: (WorktreePanes, PaneLayoutNode.Leaf) -> Void
    private let onSelectWorktreeDetail: ((WorktreePanes) -> Void)?

    public init(
        host: Host,
        isSidebar: Bool = false,
        theme: GhosttyThemeColors? = nil,
        selectedWorktreePath: String? = nil,
        focusedPaneId: String? = nil,
        isReadyToLoad: Bool = true,
        remote: RemoteWorktreeProviders = RemoteWorktreeProviders(),
        onSelect: @escaping (WorktreePanes) -> Void,
        onSelectPane: @escaping (WorktreePanes, PaneLayoutNode.Leaf) -> Void,
        navigation: SidebarNavigationState? = nil,
        navigationWindowWidth: Double = 1100,
        project: SidebarProject? = nil,
        onSelectWorktreeDetail: ((WorktreePanes) -> Void)? = nil
    ) {
        self.host = host
        self.isSidebar = isSidebar
        self.project = project
        self.theme = theme
        self.selectedWorktreePath = selectedWorktreePath
        self.focusedPaneId = focusedPaneId
        self.includeRemoteWorktrees = remote.includeRemoteWorktrees
        self.isReadyToLoad = isReadyToLoad
        self.remoteConnectionProvider = remote.connection
        self.remoteSnapshotProvider = remote.snapshot
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
        self.onSelectWorktreeDetail = onSelectWorktreeDetail
        self.navigation = navigation ?? SidebarNavigationState(prefix: "sidebar.mobile", collapsed: true)
        self.navigationWindowWidth = navigationWindowWidth
        self.remoteSidebarProvider = remote.sidebar
        self.remoteUpdatesProvider = remote.updates
    }

    private struct PendingWorktreeRouteKey: Hashable {
        let item: SidebarActivityItem?
        let loaded: Bool
    }

    private var displayedRows: [WorktreePanes]? {
        if case .loaded(let rows) = state { return rows }
        return nil
    }

    private var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    enum LoadState: Equatable {
        case loading
        case loaded([WorktreePanes])
        case error(String)
    }

    public var body: some View {
        presentedContent
        // @spec IOS-4.30
        // The readiness bit is part of the identity so an initial task that
        // mounted behind the biometric gate re-runs as soon as unlock makes
        // authenticated connections available. A successful host is latched
        // to avoid replacing the list with a spinner after every transient
        // `.inactive` → `.active` cycle.
        .task(id: WorktreeListLoadKey(
            hostID: host.id,
            isReady: isReadyToLoad
        )) {
            await loadIfReady()
        }
        .task(id: PendingWorktreeRouteKey(item: MobilePaneAttention.pendingRoute(for: navigation), loaded: isLoaded)) {
            consumePendingWorktreeRoute()
        }
        .onChange(of: selectedWorktreePath) { _, path in
            selectionIntentGeneration &+= 1
            if let path, case .loaded(let rows) = state, let worktree = rows.first(where: { $0.path == path }) {
                rememberWorktree(worktree)
            }
        }
        .onChange(of: focusedPaneId) { _, _ in
            selectionIntentGeneration &+= 1
        }
        .onChange(of: navigation.query) { _, _ in closeReport() }
        .onChange(of: navigation.selectedProjectID) { _, _ in closeReport() }
        .onChange(of: host.id) { _, _ in
            presentedHostID = host.id
            selectionIntentGeneration &+= 1
            worktreeCreation = MobileWorktreeCreation()
            pendingDelete = nil
            pendingForceDelete = nil
            remoteMacConnections = []
            reconnectingRemoteMacIDs = []
            orderMutationID = nil
            sidebarSnapshot = nil
            closeReport()
            MobilePaneAttention.consumePendingRoute(for: navigation)
            showsRemoteMacManagement = false
        }
        // Pairing a displayed host in place keeps its ID, so the push stream
        // appearing must restart observation too (IOS-4.53).
        .task(id: RemoteUpdatesKey(
            hostID: host.id,
            isReady: isReadyToLoad,
            hasUpdates: remoteUpdatesProvider != nil
        )) {
            await observeRemoteWorktrees()
        }
        .task(id: RemoteMacConnectionPollingKey(
            hostID: host.id,
            enabled: includeRemoteWorktrees,
            isReady: isReadyToLoad
        )) {
            await pollRemoteMacConnections()
        }
        .onDisappear {
            selectionIntentGeneration &+= 1
            errorToastTask?.cancel()
            closeReport()
        }
        .environment(\.editMode, $listEditMode)
    }

    private var loadContent: some View {
        Group {
            switch state {
            case .loading:
                WorktreeLoadingView(
                    hostLabel: host.label,
                    stage: loadingStage
                )
                .id(host.id)
            case .error(let msg):
                if remoteMacConnections.isEmpty {
                    worktreeLoadError(msg)
                } else {
                    List {
                        remoteMacConnectionsSection
                        Section {
                            worktreeLoadError(msg)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            case .loaded(let worktrees):
                VStack(spacing: 0) {
                    if let refreshError {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(refreshError)
                                .font(.caption)
                            Spacer()
                            Button("Retry") { Task { await refresh(reconnect: true) } }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial)
                    }
                    navigationContent(worktreeCreation.rows(in: worktrees))

                }
            }
        }
    }

    private var presentedContent: some View {
        loadContent
        .onChange(of: showsProjectRail) { _, _ in
            selectionIntentGeneration &+= 1
            navigation.resetSelection()
        }
        .confirmationDialog(
            pendingDelete?.action.dialogTitle ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pending in
            Button(pending.action.buttonLabel, role: .destructive) {
                Task { await performDelete(worktree: pending.worktree, force: false) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.action.dialogBody)
        }
        .confirmationDialog(
            "Could not delete worktree",
            isPresented: Binding(
                get: {
                    pendingForceDelete.map {
                        Self.forceDeleteMatchesHost(
                            capturedHostID: $0.requestContext.hostID,
                            currentHostID: host.id
                        )
                    } ?? false
                },
                set: { if !$0 { pendingForceDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingForceDelete
        ) { pending in
            Button("Force Delete", role: .destructive) {
                guard Self.forceDeleteMatchesHost(
                    capturedHostID: pending.requestContext.hostID,
                    currentHostID: host.id
                ) else {
                    pendingForceDelete = nil
                    return
                }
                Task { await performForceDelete(pending) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { pending in
            Text(pending.stderr + (pending.shortStatus.isEmpty ? "" : "\n\n" + pending.shortStatus))
        }
        .overlay(alignment: .bottom) {
            if let msg = errorToast {
                Text(msg)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Title is owned by the caller: the iPhone compact path
        // (`WorktreePickerView`) sets `.navigationTitle(host.label)` for
        // the navigation-stack push; the iPad path uses `HostMenu` (in
        // the sidebar nav bar's `.topBarLeading` slot) as the sole host
        // indicator, so adding `.navigationTitle` here would render a
        // redundant title in the sidebar's system nav bar (IPAD-1.2).
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isSidebar, !remoteMacConnections.isEmpty {
                    Button { showsRemoteMacManagement = true } label: {
                        Label("Remote Hosts", systemImage: "server.rack")
                    }
                    .accessibilityLabel("Manage Remote Hosts")
                }
                Button {
                    isAddSheetPresented = true
                } label: {
                    Label("Add Worktree", systemImage: "plus")
                }
                .accessibilityLabel("Add Worktree")
            }
        }
        .popover(isPresented: $showsRemoteMacManagement) {
            NavigationStack {
                List { remoteMacConnectionsSection }
                    .navigationTitle("Remote Hosts")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsRemoteMacManagement = false }
                        }
                    }
            }
            .frame(idealWidth: 360, idealHeight: 360)
            .presentationCompactAdaptation(.sheet)
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddWorktreeSheetView(
                host: host,
                remoteConnectionProvider: remoteConnectionProvider
            ) { submission in
                beginCreatingWorktree(submission)
            }
        }
    }

    private func loadIfReady() async {
        presentedHostID = host.id
        guard Self.shouldAutomaticallyLoad(
            hostID: host.id,
            loadedHostID: loadedHostID,
            isReady: isReadyToLoad
        ) else {
            return
        }
        await load()
    }

    /// Applies each frame the paired host pushes (IOS-4.52). Sidebar-only
    /// changes (order, availability and icons) arrive as frames too, with
    /// the worktree array unchanged.
    private func observeRemoteWorktrees() async {
        guard isReadyToLoad, let updates = remoteUpdatesProvider?() else { return }
        // The sibling load task also sets this; a first frame must not find
        // it unset if this task happens to run first.
        presentedHostID = host.id
        let requestHostID = host.id
        for await update in updates {
            guard Self.shouldApplyLoadResult(
                requestHostID: requestHostID,
                presentedHostID: presentedHostID,
                isCancelled: Task.isCancelled
            ) else { return }
            switch update {
            case .unavailable:
                // Keep the last usable list. The primary load/refresh paths
                // still surface transport errors to the user.
                continue
            case let .frame(.snapshot(list, metadata)):
                appliedPushCount &+= 1
                applyLoadedList(list)
                await applyNavigationMetadata(list, metadata: metadata, requestHostID: requestHostID)
            }
        }
    }

    private func pollRemoteMacConnections() async {
        guard includeRemoteWorktrees, isReadyToLoad else {
            remoteMacConnections = []
            reconnectingRemoteMacIDs = []
            return
        }
        let requestHostID = host.id
        while !Task.isCancelled {
            guard let delay = await refreshRemoteMacConnections(
                requestHostID: requestHostID
            ) else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func consumePendingWorktreeRoute() {
        guard isSidebar || !showsProjectRail || project?.id == navigation.selectedProjectID,
              let item = MobilePaneAttention.pendingRoute(for: navigation),
              case .loaded(let rows) = state,
              rows.contains(where: { $0.path == item.worktreeID && SidebarProjection.projectID($0) == item.projectID }) else { return }
        MobilePaneAttention.consumePendingRoute(for: navigation)
        // Consuming the route changes the task identity. Keep opening outside
        // that task so its cancellation cannot interrupt navigation.
        Task { await openReportTarget(item, worktrees: rows) }
    }

    @ViewBuilder
    private var remoteMacConnectionsSection: some View {
        if !remoteMacConnections.isEmpty {
            Section("Remote Hosts") {
                ForEach(remoteMacConnections) { remoteMac in
                    RemoteMacConnectionRow(
                        remoteMac: remoteMac,
                        isReconnecting: reconnectingRemoteMacIDs.contains(
                            remoteMac.id
                        ),
                        onReconnect: {
                            reconnect(remoteMac)
                        }
                    )
                }
            }
        }
    }

    private func worktreeLoadError(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                "Couldn't load worktrees",
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await load(reconnect: true) } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func load(reconnect: Bool = false) async {
        state = .loading
        loadingStage = .connecting
        refreshError = nil
        await refresh(reportsLoadingProgress: true, reconnect: reconnect)
    }

    private func projects(for worktrees: [WorktreePanes]) -> [SidebarProject] {
        let inferred = SidebarProjection.projects(worktrees)
        guard let projects = sidebarSnapshot?.projects else { return inferred }
        let known = Set(projects.map(\.id))
        return projects + inferred.filter { !known.contains($0.id) }
    }

    @ViewBuilder
    private func navigationContent(_ live: [WorktreePanes]) -> some View {
        let worktrees = reportOrder?.orderedWorktrees(live) ?? live
        let liveProjects = projects(for: live)
        let projects = reportOrder?.orderedProjects(liveProjects) ?? liveProjects
        let activityCounts = SidebarActivityCounts(items: SidebarProjection.activity(live))
        let counts = SidebarActivityCounts(items: live.flatMap { navigation.worktreeContext($0).pending }).attentionByProject
        if !isSidebar, let project {
            projectDetail(worktrees, projects: projects, projectID: project.id)
        } else if !showsProjectRail {
            VStack(spacing: 0) {
                TextField("Find any project or worktree", text: $navigation.query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
                worktreeList(worktrees.filter { navigation.worktreeContext($0).matches(query: navigation.query) })
            }
        } else if isSidebar {
            HStack(spacing: 0) {
                ProjectNavigationRail(projects: projects, counts: counts, workingCounts: activityCounts.workingByProject, icons: projectIcons,
                                      selectedID: navigation.selectedProjectID,
                                      collapsed: Binding(get: {
                    SidebarLayoutPolicy.railCollapsed(preference: navigation.railCollapsed, isMobile: true, windowWidth: navigationWindowWidth)
                }, set: { navigation.railCollapsed = $0 }),
                                      expandedWidth: $navigation.railExpandedWidth,
                                      allowsReordering: sidebarSnapshot?.supportsNavigationEditing == true && !orderMutationInFlight,
                                      canExpand: navigationWindowWidth >= 1100,
                                      selectionColor: theme?.foreground.opacity(0.16) ?? .primary.opacity(0.12),
                                      onSelect: { project in selectProject(project, worktrees: worktrees) },

                                      onMove: moveProject)
                Divider()
                projectDetail(worktrees, projects: projects)
                    .frame(minWidth: 220, maxWidth: .infinity)
            }
        } else {
            List {
                remoteMacConnectionsSection
                pendingCreationRows()
                ForEach(projects) { project in
                    NavigationLink(value: ProjectStep(host: host, project: project)) {
                        HStack(spacing: 10) {
                            ProjectIdentityView(project: project, imageData: projectIcons[project.id])
                            VStack(alignment: .leading) {
                                Text(project.name)
                                if let owner = project.owner { Text(owner.deviceLabel).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if !project.isAvailable { Text("Offline").font(.caption) }
                            HStack(spacing: 4) {
                                SidebarActivityBadge(activityCounts.workingByProject[project.id, default: 0], kind: .working)
                                SidebarActivityBadge(counts[project.id, default: 0])
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.onMove { offsets, destination in
                    guard sidebarSnapshot?.supportsNavigationEditing == true, let source = offsets.first,
                          source != destination, source + 1 != destination else { return }
                    let target = destination > source ? destination - 1 : destination
                    guard projects.indices.contains(target) else { return }
                    moveProject(projects[source].id, projects[target].id, destination > source)
                }.moveDisabled(sidebarSnapshot?.supportsNavigationEditing != true || orderMutationInFlight)
            }.toolbar { EditButton() }
        }
    }

    private func projectDetail(_ worktrees: [WorktreePanes], projects: [SidebarProject], projectID: String? = nil) -> some View {
        let selectedProjectID = projectID ?? navigation.selectedProjectID
        return VStack(spacing: 0) {
            if !isSidebar {
                pendingCreationRows(excludingProjectID: selectedProjectID)
                    .padding(.horizontal, 10)
            }
            if let selected = projects.first(where: { $0.id == selectedProjectID }), !selected.isAvailable {
                Text("The owning Mac is offline.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Find any project or worktree", text: $navigation.query).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            worktreeList(worktrees.filter {
                navigation.query.isEmpty ? SidebarProjection.projectID($0) == selectedProjectID
                    : navigation.worktreeContext($0).matches(query: navigation.query)
            })
        }
    }

    /// Compact navigation may still show the project picker or another
    /// project's detail while the requested worktree is being created.
    private func pendingCreationRows(excludingProjectID: String? = nil) -> some View {
        let snapshot: [WorktreePanes]
        if case .loaded(let rows) = state { snapshot = rows } else { snapshot = [] }
        return ForEach(worktreeCreation.pendingRows(in: snapshot).filter {
            SidebarProjection.projectID($0) != excludingProjectID
        }, id: \.path) { worktree in
            Button { beginSelectingWorktree(worktree) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.repoDisplayName).font(.caption).foregroundStyle(.secondary)
                    WorktreeRowContent(worktree: worktree, theme: theme,
                        isActive: false, isOpening: false, attentionCount: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!worktree.showsCreationProgress)
        }
    }

    private func showReport(_ worktree: WorktreePanes) {
        guard reportWorktreeID == nil, case .loaded(let worktrees) = state else { return }
        selectionIntentGeneration &+= 1
        reportOrder = SidebarWorktreeReportOrder(worktrees: worktrees, projects: projects(for: worktrees))
        reportWorktreeID = worktree.path
    }

    private func closeReport() {
        guard reportWorktreeID != nil else { return }
        selectionIntentGeneration &+= 1
        reportWorktreeID = nil
        reportOrder = nil
    }

    private func openReportTarget(_ item: SidebarActivityItem, worktrees: [WorktreePanes]) async -> Bool {
        let token = navigation.beginOpening(item)
        let succeeded = await openAttention(item, worktrees: worktrees)
        navigation.finishOpening(token, succeeded: succeeded, navigateToProject: true)
        return succeeded
    }

    private func selectProject(_ project: SidebarProject, worktrees: [WorktreePanes]) {
        Self.applyProjectSelection(project, navigation: navigation, selectionGeneration: &selectionIntentGeneration)
        if let selectedWorktreePath, let previous = worktrees.first(where: { $0.path == selectedWorktreePath }) {
            navigation.rememberedWorktrees[SidebarProjection.projectID(previous)] = previous.path
        }
        if isSidebar, project.isAvailable {
            let available = worktrees.filter { SidebarProjection.projectID($0) == project.id }
            if let target = available.first(where: { $0.path == navigation.rememberedWorktrees[project.id] }) ?? available.first {
                beginSelectingWorktree(target)
            }
        }
    }

    static func applyProjectSelection(_ project: SidebarProject, navigation: SidebarNavigationState, selectionGeneration: inout UInt64) {
        // Invalidate before changing modes: offline and compact project picks
        // do not call beginSelectingWorktree, but must still cancel old opens.
        selectionGeneration &+= 1
        navigation.showProject(project.id)
    }

    private func moveProject(_ id: String, _ target: String, _ after: Bool) {
        performNavigationMutation(.moveProject(id: id, relativeTo: target, after: after))
    }

    private func performNavigationMutation(_ request: WorktreeManagementRequest) {
        guard !orderMutationInFlight, sidebarSnapshot?.supportsNavigationEditing == true else { return }
        let requestHostID = host.id
        let provider: RemoteConnectionProvider? = remoteConnectionProvider
        let mutationID = UUID()
        orderMutationID = mutationID
        Task {
            defer { if orderMutationID == mutationID { orderMutationID = nil } }
            do {
                let response = try await RelayedWorktreeManagementClient.send(request, using: provider)
                guard presentedHostID == requestHostID, orderMutationID == mutationID else { return }
                if case .error(_, let message, _, _) = response { showErrorToast(message) }
                await refresh()
            } catch {
                guard presentedHostID == requestHostID, orderMutationID == mutationID else { return }
                showErrorToast("Couldn't save the order. Reconnect and try again.")
            }
        }
    }

    private func openAttention(_ item: SidebarActivityItem, worktrees: [WorktreePanes]) async -> Bool {
        guard let worktree = worktrees.first(where: { $0.path == item.worktreeID }), worktree.state.hasOnDiskWorktree else {
            showErrorToast("This worktree is no longer available."); return false
        }
        guard projects(for: worktrees).first(where: { $0.id == item.projectID })?.isAvailable != false else {
            showErrorToast("The owning Mac is offline."); return false
        }
        selectionIntentGeneration &+= 1
        let generation = selectionIntentGeneration
        let requestHostID = host.id
        let provider: RemoteConnectionProvider? = remoteConnectionProvider
        do {
            var target = worktree
            if target.state == .closed {
                let response = try await RelayedWorktreeManagementClient.send(.open(worktreeID: target.path), using: provider)
                guard presentedHostID == requestHostID, generation == selectionIntentGeneration else { return false }
                guard response == .ok else { showErrorToast("Couldn't open the worktree."); return false }
                func checkCurrent() throws {
                    guard presentedHostID == requestHostID, generation == selectionIntentGeneration else { throw CancellationError() }
                }
                func fetch() async throws -> [WorktreePanes] {
                    let pushes = appliedPushCount
                    let list = try await fetchWorktrees()
                    try checkCurrent()
                    // A newer push supersedes these rows for display and for
                    // deciding what to open.
                    guard appliedPushCount == pushes else { return displayedRows ?? list }
                    applyLoadedList(list)
                    return list
                }
                let path = target.path
                if let running = try await WorktreeLayoutAwait.poll(rows: try await fetch(), fetch: fetch, checkCurrent: checkCurrent,
                        ready: { rows in rows.first { $0.path == path && $0.layout != nil } }) {
                    target = running
                }
            }
            guard presentedHostID == requestHostID, generation == selectionIntentGeneration, target.layout != nil else { return false }
            var currentItem = item
            currentItem.worktreeID = target.path
            let paneID = SidebarProjection.attentionPaneRoute(for: item, in: target)
                ?? (item.paneID == nil ? target.layout?.leaves.first?.sessionName : nil)
            let leaf = target.layout?.leaves.first { $0.sessionName == paneID }
            guard item.paneID == nil || leaf != nil else {
                showErrorToast("This pane is no longer available."); return false
            }
            // A stopped recap routes to a pane but remains worktree-scoped for acknowledgement.
            if item.paneID != nil { currentItem.paneID = paneID }
            let supportsExactAcknowledgement = projects(for: worktrees)
                .first(where: { $0.id == item.projectID })?.supportsWorktreeEditing == true
            guard presentedHostID == requestHostID, generation == selectionIntentGeneration else { return false }
            if let leaf {
                onSelectPane(target, leaf)
            } else if let onSelectWorktreeDetail { onSelectWorktreeDetail(target) }
            else { onSelect(target) }
            // The visit has occurred. A delayed acknowledgement must not consume
            // an unopened request or later replace a newer navigation choice.
            if includeRemoteWorktrees, let request = SidebarInteractionPolicy.acknowledgementOnOpen(
                for: currentItem, supportsExactAcknowledgement: supportsExactAcknowledgement
            ) {
                Task {
                    do {
                        let response = try await RelayedWorktreeManagementClient.send(request, using: provider)
                        guard presentedHostID == requestHostID else { return }
                        if case .error(let code, let message, _, _) = response, code != "occurrence-changed" { showErrorToast(message) }
                    } catch {
                        guard presentedHostID == requestHostID else { return }
                        showErrorToast("Couldn't mark this request as viewed.")
                    }
                }
            }
            return true
        } catch {
            // A newer selection supersedes silently; a connection-layer
            // cancellation still reports the failure.
            guard presentedHostID == requestHostID, generation == selectionIntentGeneration else { return false }
            showErrorToast("Couldn't open this request on the owning Mac.")
            return false
        }
    }

    static func shouldApplyNavigationSnapshot(_ snapshot: PanesStateMessage?, matching rows: [WorktreePanes]) -> Bool {
        guard case let .snapshot(snapshotRows, _)? = snapshot else { return false }
        return snapshotRows == rows
    }

    /// `pushes` is the applied-push count the pulled `list` was accepted
    /// under; a push that lands while the metadata is fetched supersedes it.
    private func updateNavigationMetadata(_ list: [WorktreePanes], requestHostID: UUID, pushes: UInt64) async {
        let snapshot: PanesStateMessage?
        if let remoteSidebarProvider { snapshot = await remoteSidebarProvider(list) }
        else { snapshot = .snapshot(list) }
        guard appliedPushCount == pushes,
              Self.shouldApplyNavigationSnapshot(snapshot, matching: list),
              case let .snapshot(_, metadata)? = snapshot else { return }
        await applyNavigationMetadata(list, metadata: metadata, requestHostID: requestHostID)
    }

    private func applyNavigationMetadata(_ list: [WorktreePanes], metadata: SidebarSnapshot?, requestHostID: UUID) async {
        guard presentedHostID == requestHostID else { return }
        if sidebarSnapshot != metadata { sidebarSnapshot = metadata }
        let projects = metadata?.projects ?? SidebarProjection.projects(list)
        navigation.reconcile(worktrees: list, projects: projects)
        if navigation.selectedProjectID == nil || !projects.contains(where: { $0.id == navigation.selectedProjectID }) {
            navigation.selectedProjectID = list.first(where: { $0.path == selectedWorktreePath }).map(SidebarProjection.projectID) ?? projects.first?.id
        }
        projectIconCache.reconcile(projects)
        for project in projects where project.isAvailable {
            guard let revision = project.iconRevision else { continue }
            await projectIconCache.load(for: project) {
                let response = try? await RelayedWorktreeManagementClient.send(
                    .projectIcon(repositoryID: project.repositoryID, revision: revision), using: remoteConnectionProvider)
                guard presentedHostID == requestHostID else { return nil }
                if case .icon(let data) = response { return data }
                return nil
            }
        }
    }

    private func worktreeList(_ worktrees: [WorktreePanes]) -> some View {
        let projects = projects(for: worktrees)
        let regions = WorktreePickerGrouping.regions(worktrees, searching: !navigation.query.isEmpty)
        let scrollKey = navigation.query.isEmpty ? SidebarLayoutPolicy.projectFilter(selectedID: navigation.selectedProjectID, showsProjectRail: showsProjectRail) : nil
        return ScrollViewReader { proxy in
                    List {
                        if !showsProjectRail { remoteMacConnectionsSection }
                        ForEach(regions) { region in
                            if region.kind == .tasks, regions.contains(where: { $0.kind == .pinned }) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Divider()
                                    Text("Worktrees").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                            ForEach(region.groups) { group in
                                Section {
                                    let projectID = group.worktrees.first.map(SidebarProjection.projectID)
                                    let ownerAllowsEditing = projects
                                        .first(where: { $0.id == projectID })?.supportsWorktreeEditing == true
                                    SidebarWorktreeRows(worktrees: group.worktrees,
                                        allowsReordering: listEditMode.isEditing && navigation.query.isEmpty && ownerAllowsEditing && !orderMutationInFlight,
                                        onMove: { source, target, after in
                                            guard let repositoryID = source.repositoryID else { return }
                                            performNavigationMutation(.moveWorktree(repositoryID: repositoryID, worktreeID: source.path, relativeTo: target.path, after: after))
                                        }, rowInsets: SidebarWorktreeListStyle.projectRowInsets,
                                        showsSections: navigation.query.isEmpty,
                                        section: region.sidebarSection) { wt in
                                        WorktreeBlock(
                                            worktree: wt,
                                            project: projects.first { $0.id == SidebarProjection.projectID(wt) },
                                            projectIconData: projectIcons[SidebarProjection.projectID(wt)],
                                            theme: theme,
                                            isActive: wt.path == selectedWorktreePath,
                                            isOpening: openingWorktrees.contains(
                                                OpeningWorktreeKey(
                                                    hostID: host.id,
                                                    path: wt.path
                                                )
                                            ),
                                            focusedPaneId: focusedPaneId,
                                            projectColumn: true,
                                            context: navigation.worktreeContext(wt),
                                            onSelect: {
                                                beginSelectingWorktree(wt)
                                            },
                                            onSelectPane: { leaf in
                                                rememberWorktree(wt)
                                                acknowledgeViewedPane(wt, leaf: leaf)
                                                selectionIntentGeneration &+= 1
                                                onSelectPane(wt, leaf)
                                            },
                                            onReport: { showReport(wt) }
                                        )
                                        .popover(isPresented: Binding(
                                            get: { reportWorktreeID == wt.path },
                                            set: { if !$0, reportWorktreeID == wt.path { closeReport() } }
                                        ), arrowEdge: .leading) {
                                            MobileWorktreeReportContent(context: navigation.worktreeContext(wt), onOpen: {
                                                let rows: [WorktreePanes]
                                                if case .loaded(let live) = state { rows = live } else { rows = worktrees }
                                                return await openReportTarget(MobilePaneAttention.openTarget(for: navigation.worktreeContext(wt)), worktrees: rows)
                                            }, onDismiss: {
                                                let context = navigation.worktreeContext(wt)
                                                navigation.dismissRequest(in: context)
                                                closeReport()
                                            },
                                            onClose: { if reportWorktreeID == wt.path { closeReport() } },
                                            host: host, remoteConnectionProvider: remoteConnectionProvider)
                                            .presentationCompactAdaptation(.sheet)
                                        }
                                        .id(wt.sidebar?.id ?? wt.path)
                                        .background(GeometryReader { geometry in
                                            let frame = geometry.frame(in: .named(worktreeScrollSpace))
                                            Color.clear.preference(key: SidebarWorktreeViewportPreference.self, value: [
                                                SidebarWorktreeViewportRow(id: wt.sidebar?.id ?? wt.path,
                                                    minY: frame.minY, maxY: frame.maxY, projectID: SidebarProjection.projectID(wt))
                                            ])
                                        })
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if let action = WorktreePickerGrouping.swipeAction(for: wt) {
                                                Button(role: .destructive) {
                                                    pendingDelete = PendingDelete(worktree: wt, action: action)
                                                } label: {
                                                    Label(action.buttonLabel, systemImage: action == .dismiss ? "eye.slash" : "trash")
                                                }
                                            }
                                        }
                                    }
                                } header: {
                                    if (!showsProjectRail && project == nil) || !navigation.query.isEmpty {
                                        Text(group.title).foregroundColor(theme?.sidebarPrimaryText(isActive: false))
                                    }
                                }
                            }
                        }
                    }
                    // Use the flat project column on iPhone and iPad.
                    .modifier(SidebarWorktreeListStyle(projectColumn: true))
                    .scrollContentBackground(.hidden)
                    .refreshable { await refresh() }
                    .toolbar { EditButton() }
                    .coordinateSpace(name: worktreeScrollSpace)
                    .onPreferenceChange(SidebarWorktreeViewportPreference.self) { positions in
                        guard !restoringWorktreeScroll, let scrollKey, restoredWorktreeProjectID == scrollKey,
                              let anchor = SidebarWorktreeViewportRow.topVisible(in: positions.filter { $0.projectID == scrollKey }) else { return }
                        navigation.scrollAnchors[scrollKey] = anchor
                    }
                    .task(id: scrollKey) {
                        restoringWorktreeScroll = true
                        defer {
                            restoringWorktreeScroll = false
                            if !Task.isCancelled { restoredWorktreeProjectID = scrollKey }
                        }
                        guard let scrollKey, let anchor = navigation.scrollAnchors[scrollKey] else { return }
                        // List installs its new row IDs after the project changes.
                        // Restore through ScrollViewReader; List does not consume
                        // the ScrollView-only scrollPosition binding.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(anchor, anchor: .top)
                        await Task.yield()
                    }
        }
    }

    private func refresh(reportsLoadingProgress: Bool = false, reconnect: Bool = false) async {
        let requestHostID = host.id
        let onProgress: RemoteWorktreeLoadProgress?
        if reportsLoadingProgress {
            onProgress = { stage in
                guard Self.shouldApplyLoadResult(
                    requestHostID: requestHostID,
                    presentedHostID: presentedHostID,
                    isCancelled: Task.isCancelled
                ), case .loading = state else { return }
                loadingStage = stage
            }
        } else {
            onProgress = nil
        }

        let pushes = appliedPushCount
        do {
            let list = try await fetchWorktrees(
                onProgress: onProgress,
                reconnect: reconnect
            )
            guard Self.shouldApplyLoadResult(
                requestHostID: requestHostID,
                presentedHostID: presentedHostID,
                isCancelled: Task.isCancelled
            ), appliedPushCount == pushes else { return }
            applyLoadedList(list)
            await updateNavigationMetadata(list, requestHostID: requestHostID, pushes: pushes)
        } catch is CancellationError {
            return
        } catch {
            guard shouldApplyLoadFailure(requestHostID: requestHostID) else { return }
            applyRefreshFailure("Couldn't reach the server.")
        }
    }

    private func shouldApplyLoadFailure(requestHostID: UUID) -> Bool {
        Self.shouldApplyLoadResult(
            requestHostID: requestHostID,
            presentedHostID: presentedHostID,
            isCancelled: Task.isCancelled
        )
    }

    private func applyRefreshFailure(_ message: String) {
        if case .loaded = state {
            refreshError = message
        }
        state = Self.loadState(afterFailure: message, current: state)
    }

    private func refreshRemoteMacConnections(requestHostID: UUID) async
        -> Duration? {
        guard let provider = remoteConnectionProvider else { return nil }
        let response: WorktreeManagementResponse
        do {
            response = try await RelayedWorktreeManagementClient.send(
                .listRemoteMacConnections,
                using: provider
            )
        } catch {
            return .seconds(5)
        }
        guard Self.shouldApplyLoadResult(
            requestHostID: requestHostID,
            presentedHostID: presentedHostID,
            isCancelled: Task.isCancelled
        ) else {
            return nil
        }
        switch response {
        case .remoteMacConnections(let connections):
            remoteMacConnections = connections
            return .seconds(5)
        case let .error(code, _, _, _) where code == "malformed-request":
            return .seconds(60)
        default:
            return .seconds(5)
        }
    }

    private func reconnect(_ remoteMac: RemoteMacConnectionSummary) {
        guard !reconnectingRemoteMacIDs.contains(remoteMac.id) else { return }
        let requestHostID = host.id
        let provider: RemoteConnectionProvider? = remoteConnectionProvider
        reconnectingRemoteMacIDs.insert(remoteMac.id)
        Task {
            defer {
                if requestHostID == presentedHostID {
                    reconnectingRemoteMacIDs.remove(remoteMac.id)
                }
            }
            do {
                let response = try await RelayedWorktreeManagementClient.send(
                    .connectRemoteMac(
                        deviceID: remoteMac.deviceID,
                        fingerprint: remoteMac.fingerprint
                    ),
                    using: provider
                )
                guard Self.shouldApplyLoadResult(
                    requestHostID: requestHostID,
                    presentedHostID: presentedHostID,
                    isCancelled: Task.isCancelled
                ) else {
                    return
                }
                switch response {
                case .ok:
                    _ = await refreshRemoteMacConnections(
                        requestHostID: requestHostID
                    )
                    await refresh()
                case let .error(_, message, _, _):
                    showErrorToast(message)
                    _ = await refreshRemoteMacConnections(
                        requestHostID: requestHostID
                    )
                default:
                    showErrorToast(
                        "The connected Mac returned an unexpected response."
                    )
                }
            } catch {
                guard Self.shouldApplyLoadResult(
                    requestHostID: requestHostID,
                    presentedHostID: presentedHostID,
                    isCancelled: Task.isCancelled
                ) else {
                    return
                }
                showErrorToast("Couldn't ask the connected Mac to reconnect.")
            }
        }
    }

    static func loadState(
        afterFailure message: String,
        current: LoadState
    ) -> LoadState {
        if case .loaded = current {
            return current
        }
        return .error(message)
    }

    static func shouldAutomaticallyLoad(
        hostID: UUID,
        loadedHostID: UUID?,
        isReady: Bool
    ) -> Bool {
        isReady && loadedHostID != hostID
    }

    static func shouldApplyLoadResult(
        requestHostID: UUID,
        presentedHostID: UUID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestHostID == presentedHostID
    }

    /// @spec IOS-4.31
    /// A refresh or reconnect re-reads rows the host already pushed, and a
    /// sidebar-only frame repeats the worktree array. Suppressing those no-op
    /// writes keeps the live multi-pane hierarchy and its `SessionClient`s
    /// out of SwiftUI's update path until pane metadata or topology actually
    /// changes.
    private func applyLoadedList(_ list: [WorktreePanes]) {
        if let reportWorktreeID, !list.contains(where: { $0.path == reportWorktreeID }) { closeReport() }
        let next = LoadState.loaded(list)
        let changed = Self.shouldPublishLoadedList(
            current: state,
            next: list
        )
        loadedHostID = host.id
        refreshError = nil
        if changed { state = next }
        if let created = worktreeCreation.takeReadySelection(in: list, generation: selectionIntentGeneration) {
            rememberWorktree(created)
            onSelect(created)
        }
    }

    static func shouldPublishLoadedList(
        current: LoadState,
        next: [WorktreePanes]
    ) -> Bool {
        current != .loaded(next)
    }

    private func fetchWorktrees(
        onProgress: RemoteWorktreeLoadProgress? = nil,
        reconnect: Bool = false
    ) async throws -> [WorktreePanes] {
        guard let remoteSnapshotProvider else {
            throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
        }
        return try await remoteSnapshotProvider(onProgress, reconnect)
    }

    static func requiresManagementOpen(
        _ worktree: WorktreePanes,
        includesRemoteWorktrees: Bool,
        providerAvailable: Bool
    ) -> Bool {
        worktree.state == .closed
            && includesRemoteWorktrees
            && providerAvailable
    }

    static func forceDeleteMatchesHost(
        capturedHostID: UUID,
        currentHostID: UUID
    ) -> Bool {
        capturedHostID == currentHostID
    }

    static func shouldApplySelectionIntent(
        capturedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        capturedGeneration == currentGeneration
    }

    private func rememberWorktree(_ worktree: WorktreePanes) {
        let id = SidebarProjection.projectID(worktree)
        navigation.rememberedWorktrees[id] = worktree.path
        navigation.selectedProjectID = id
    }

    private func recordViewedStop(_ worktree: WorktreePanes) {
        if let stop = SidebarProjection.activity([worktree]).first(where: { $0.agentStop != nil }) {
            navigation.opened(stop)
        }
    }

    private func acknowledgeViewedPane(_ worktree: WorktreePanes, leaf: PaneLayoutNode.Leaf) {
        let context = navigation.worktreeContext(worktree)
        let items = context.pending.filter { $0.paneID == leaf.sessionName || $0.agentStop != nil }
        let supportsExact = projects(for: [worktree]).first { $0.id == context.item.projectID }?.supportsWorktreeEditing == true
        for item in items {
            navigation.opened(item)
            guard includeRemoteWorktrees,
                  let request = SidebarInteractionPolicy.acknowledgementOnOpen(for: item, supportsExactAcknowledgement: supportsExact) else { continue }
            let requestHostID = host.id
            let provider: RemoteConnectionProvider? = remoteConnectionProvider
            Task {
                let response = try? await RelayedWorktreeManagementClient.send(request, using: provider)
                guard presentedHostID == requestHostID else { return }
                if response == nil { showErrorToast("Couldn't mark this request as viewed.") }
                if case .error(let code, let message, _, _) = response, code != "occurrence-changed" { showErrorToast(message) }
            }
        }
    }

    private func beginSelectingWorktree(_ worktree: WorktreePanes) {
        rememberWorktree(worktree)
        selectionIntentGeneration &+= 1
        let generation = selectionIntentGeneration
        let selectionHost = host
        let provider: RemoteConnectionProvider? = remoteConnectionProvider
        let shouldIncludeRemoteWorktrees = includeRemoteWorktrees
        if worktree.showsCreationProgress {
            onSelect(worktree)
            return
        }
        Task {
            await selectWorktree(
                worktree,
                generation: generation,
                selectionHost: selectionHost,
                provider: provider,
                includeRemoteWorktrees: shouldIncludeRemoteWorktrees
            )
        }
    }

    /// Closed worktrees shared over the authenticated management channel
    /// have no pane layout yet. Start the owning Mac's worktree, then poll
    /// until the authoritative running layout arrives before navigating.
    private func selectWorktree(
        _ worktree: WorktreePanes,
        generation: UInt64,
        selectionHost: Host,
        provider: RemoteConnectionProvider?,
        includeRemoteWorktrees: Bool
    ) async {
        func selectionIsCurrent() -> Bool {
            selectionHost.id == host.id
                && Self.shouldApplySelectionIntent(
                    capturedGeneration: generation,
                    currentGeneration: selectionIntentGeneration
                )
        }
        guard Self.requiresManagementOpen(
            worktree,
            includesRemoteWorktrees: includeRemoteWorktrees,
            providerAvailable: provider != nil
        ) else {
            if selectionIsCurrent() {
                onSelect(worktree)
                recordViewedStop(worktree)
            }
            return
        }
        let openingKey = OpeningWorktreeKey(
            hostID: selectionHost.id,
            path: worktree.path
        )
        guard !openingWorktrees.contains(openingKey) else { return }
        openingWorktrees.insert(openingKey)
        defer { openingWorktrees.remove(openingKey) }

        do {
            let response = try await RelayedWorktreeManagementClient.send(
                .open(worktreeID: worktree.path),
                using: provider
            )
            guard selectionIsCurrent() else { return }
            guard response == .ok else {
                if case let .error(_, message, _, _) = response {
                    showErrorToast(message)
                } else {
                    showErrorToast(
                        "The remote Mac returned an unexpected response."
                    )
                }
                return
            }

            func checkCurrent() throws {
                guard !Task.isCancelled, selectionIsCurrent() else { throw CancellationError() }
            }
            func fetch() async throws -> [WorktreePanes] {
                let pushes = appliedPushCount
                let list = try await fetchWorktrees()
                try checkCurrent()
                guard appliedPushCount == pushes else { return displayedRows ?? list }
                state = .loaded(list)
                return list
            }
            if let opened = try await WorktreeLayoutAwait.poll(rows: try await fetch(), fetch: fetch, checkCurrent: checkCurrent,
                    ready: { rows in rows.first { $0.path == worktree.path && $0.state == .running && $0.layout != nil } }) {
                onSelect(opened)
                recordViewedStop(opened)
                return
            }
            showErrorToast("The worktree started, but its panes are not ready.")
        } catch is CancellationError {
            return
        } catch {
            if selectionIsCurrent() {
                showErrorToast("Couldn't reach the remote Mac.")
            }
        }
    }

    /// Own the request outside the sheet so dismissal never cancels creation.
    private func beginCreatingWorktree(_ submission: AddWorktreeSheetView.Submission) {
        let requestHost = host
        let provider: RemoteConnectionProvider? = remoteConnectionProvider
        let request = submission.request
        let repository = submission.repository
        let rows: [WorktreePanes]
        if case .loaded(let list) = state { rows = list } else { rows = [] }
        let targetProject = projects(for: rows).first {
            $0.repositoryID == repository.id && $0.owner?.deviceID == repository.origin?.deviceID
        }
        let temporaryID = "creating-" + UUID().uuidString
        let placeholder = WorktreePanes(
            path: temporaryID,
            displayName: (request.worktreeName as NSString).lastPathComponent,
            repoDisplayName: repository.displayName,
            repositoryID: repository.id,
            displayBranch: request.branchName, state: .creating,
            isMainCheckout: false, prBadge: nil, stats: nil,
            attentionText: nil, layout: nil, origin: repository.origin,
            sidebar: targetProject.map {
                SidebarWorktreeMetadata(id: temporaryID, projectID: $0.id, isPinned: false)
            }
        )
        closeReport()
        selectionIntentGeneration &+= 1
        let id = worktreeCreation.begin(
            placeholder: placeholder, knownPaths: Set(rows.map(\.path)),
            generation: selectionIntentGeneration
        )
        // Reveal the destination project without selecting its unfinished row.
        navigation.selectedProjectID = targetProject?.id ?? SidebarProjection.projectID(placeholder)
        navigation.query = ""
        isAddSheetPresented = false
        Task {
            do {
                let worktreePath: String
                let result = try await RelayedWorktreeManagementClient.send(
                    .create(repositoryID: request.repoPath,
                            worktreeName: request.worktreeName,
                            branchName: request.branchName,
                            existingSource: submission.existingSource),
                    using: provider
                )
                switch result {
                case let .created(worktreeID, _):
                    worktreePath = worktreeID
                case let .error(_, message, _, _):
                    throw CreateWorktreeClient.CreateError.serverInternal(message)
                default:
                    throw CreateWorktreeClient.CreateError.serverInternal("The remote Mac returned an unexpected response.")
                }
                guard presentedHostID == requestHost.id else { return }
                worktreeCreation.complete(id, worktreePath: worktreePath)
                // A pushed frame may already have delivered the ready layout
                // while the management response was still in flight.
                if case .loaded(let list) = state { applyLoadedList(list) }
                await refresh()
            } catch {
                guard presentedHostID == requestHost.id else { return }
                worktreeCreation.fail(id)
                let message = (error as? CreateWorktreeClient.CreateError)?.userMessage
                    ?? CreateWorktreeClient.CreateError.transport.userMessage
                showErrorToast("Could not create worktree: " + message)
                await refresh()
            }
        }
    }

    /// Issue the delete request; on success refresh in place, on
    /// forceable failure surface the Force Delete confirmation, on
    /// any other failure surface a transient error toast.
    private func performDelete(worktree: WorktreePanes, force: Bool) async {
        await sendDelete(
            worktreePath: worktree.path,
            force: force,
            requestContext: DeleteRequestContext(
                hostID: host.id,
                remoteConnectionProvider: remoteConnectionProvider
            )
        )
    }

    /// User confirmed Force Delete on a force-allowed error — re-issue
    /// with `force: true` against the host the first attempt targeted.
    private func performForceDelete(_ pending: PendingForceDelete) async {
        await sendDelete(
            worktreePath: pending.worktreePath,
            force: true,
            requestContext: pending.requestContext
        )
    }

    private func sendDelete(
        worktreePath: String,
        force: Bool,
        requestContext: DeleteRequestContext
    ) async {
        do {
            let response = try await RelayedWorktreeManagementClient.send(
                .delete(worktreeID: worktreePath, force: force),
                using: requestContext.remoteConnectionProvider
            )
            guard case .deleted = response else {
                handleRemoteDeleteResponse(
                    response,
                    worktreePath: worktreePath,
                    requestContext: requestContext
                )
                return
            }
            await refresh()
        } catch {
            showErrorToast("Couldn't reach the server.")
        }
    }

    /// What a non-`.deleted` delete response asks the UI to do.
    enum DeleteFailure: Equatable {
        /// Present the Force Delete confirmation (IOS-9.8).
        case confirmForce(stderr: String, shortStatus: String)
        /// Present a non-retryable error toast.
        case toast(String)
    }

    /// IOS-9.8: a force-allowed error asks for confirmation; any other
    /// response is a flat, non-retryable toast.
    static func deleteFailure(for response: WorktreeManagementResponse) -> DeleteFailure {
        if case let .error(_, message, forceAllowed, shortStatus) = response {
            return forceAllowed
                ? .confirmForce(stderr: message, shortStatus: shortStatus ?? "")
                : .toast(message)
        }
        return .toast("The remote Mac returned an unexpected response.")
    }

    private func handleRemoteDeleteResponse(
        _ response: WorktreeManagementResponse,
        worktreePath: String,
        requestContext: DeleteRequestContext
    ) {
        switch Self.deleteFailure(for: response) {
        case let .confirmForce(stderr, shortStatus):
            pendingForceDelete = PendingForceDelete(
                worktreePath: worktreePath,
                stderr: stderr,
                shortStatus: shortStatus,
                requestContext: requestContext
            )
        case let .toast(message):
            showErrorToast(message)
        }
    }

    private func showErrorToast(_ message: String) {
        errorToastTask?.cancel()
        withAnimation { errorToast = message }
        errorToastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation { errorToast = nil }
                }
            }
        }
    }

}

private struct RemoteMacConnectionPollingKey: Hashable {
    let hostID: UUID
    let enabled: Bool
    let isReady: Bool
}

private struct WorktreeListLoadKey: Hashable {
    let hostID: UUID
    let isReady: Bool
}

private struct RemoteUpdatesKey: Hashable {
    let hostID: UUID
    let isReady: Bool
    let hasUpdates: Bool
}
#endif
