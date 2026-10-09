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
    @State private var loadedHostID: UUID?
    @State private var presentedHostID: UUID?
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var remoteSidebarProvider: (@MainActor ([WorktreePanes]) async -> PanesStateMessage?)?
    private var navigationWindowWidth: Double

    private struct PendingDelete: Identifiable, Equatable {
        let id = UUID()
        let worktree: WorktreePanes
        let action: WorktreePickerSwipeAction
    }

    private struct DeleteRequestContext {
        let hostID: UUID
        let baseURL: URL
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
    public let onSelectPane: (PaneLayoutNode.Leaf) -> Void
    private let onSelectWorktreeDetail: ((WorktreePanes) -> Void)?
    private let onSelectPaneWithWorktree: ((WorktreePanes, PaneLayoutNode.Leaf) -> Void)?
    public let onListChanged: ([WorktreePanes]) -> Void
    public let externalRefreshToken: Int

    public init(
        host: Host,
        theme: GhosttyThemeColors? = nil,
        selectedWorktreePath: String? = nil,
        focusedPaneId: String? = nil,
        includeRemoteWorktrees: Bool = false,
        isReadyToLoad: Bool = true,
        remoteConnectionProvider: RemoteConnectionProvider? = nil,
        remoteSnapshotProvider: RemoteWorktreeSnapshotProvider? = nil,
        onSelect: @escaping (WorktreePanes) -> Void,
        onSelectPane: @escaping (PaneLayoutNode.Leaf) -> Void,
        onListChanged: @escaping ([WorktreePanes]) -> Void = { _ in },
        externalRefreshToken: Int = 0,
        navigation: SidebarNavigationState? = nil,
        navigationWindowWidth: Double = 1100,
        remoteSidebarProvider: (@MainActor ([WorktreePanes]) async -> PanesStateMessage?)? = nil,
        project: SidebarProject? = nil
    ) {
        self.host = host
        self.project = project
        self.theme = theme
        self.selectedWorktreePath = selectedWorktreePath
        self.focusedPaneId = focusedPaneId
        self.includeRemoteWorktrees = includeRemoteWorktrees
        self.isReadyToLoad = isReadyToLoad
        self.remoteConnectionProvider = remoteConnectionProvider
        self.remoteSnapshotProvider = remoteSnapshotProvider
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
        self.onSelectWorktreeDetail = nil
        self.onSelectPaneWithWorktree = nil
        self.onListChanged = onListChanged
        self.externalRefreshToken = externalRefreshToken
        self.navigation = navigation ?? SidebarNavigationState(prefix: "sidebar.mobile", collapsed: true)
        self.navigationWindowWidth = navigationWindowWidth
        self.remoteSidebarProvider = remoteSidebarProvider
    }

    init(
        host: Host,
        theme: GhosttyThemeColors? = nil,
        selectedWorktreePath: String? = nil,
        focusedPaneId: String? = nil,
        includeRemoteWorktrees: Bool = false,
        isReadyToLoad: Bool = true,
        remoteConnectionProvider: RemoteConnectionProvider? = nil,
        remoteSnapshotProvider: RemoteWorktreeSnapshotProvider? = nil,
        onSelect: @escaping (WorktreePanes) -> Void,
        onSelectPaneWithWorktree: @escaping (WorktreePanes, PaneLayoutNode.Leaf) -> Void,
        onListChanged: @escaping ([WorktreePanes]) -> Void = { _ in },
        externalRefreshToken: Int = 0,
        navigation: SidebarNavigationState? = nil,
        navigationWindowWidth: Double = 1100,
        remoteSidebarProvider: (@MainActor ([WorktreePanes]) async -> PanesStateMessage?)? = nil,
        project: SidebarProject? = nil,
        onSelectWorktreeDetail: ((WorktreePanes) -> Void)? = nil
    ) {
        self.host = host
        self.project = project
        self.theme = theme
        self.selectedWorktreePath = selectedWorktreePath
        self.focusedPaneId = focusedPaneId
        self.includeRemoteWorktrees = includeRemoteWorktrees
        self.isReadyToLoad = isReadyToLoad
        self.remoteConnectionProvider = remoteConnectionProvider
        self.remoteSnapshotProvider = remoteSnapshotProvider
        self.onSelect = onSelect
        self.onSelectPane = { _ in }
        self.onSelectWorktreeDetail = onSelectWorktreeDetail
        self.onSelectPaneWithWorktree = onSelectPaneWithWorktree
        self.onListChanged = onListChanged
        self.externalRefreshToken = externalRefreshToken
        self.navigation = navigation ?? SidebarNavigationState(prefix: "sidebar.mobile", collapsed: true)
        self.navigationWindowWidth = navigationWindowWidth
        self.remoteSidebarProvider = remoteSidebarProvider
    }

    private struct PendingWorktreeRouteKey: Hashable {
        let item: SidebarActivityItem?
        let loaded: Bool
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
        .task(id: externalRefreshToken) {
            guard externalRefreshToken != 0 else { return }
            await refresh()
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
        .task(id: RemotePollingKey(
            hostID: host.id,
            enabled: includeRemoteWorktrees,
            isReady: isReadyToLoad
        )) {
            await pollRemoteWorktrees()
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
                    navigationContent(worktrees)

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
        .overlay(alignment: .top) {
            if let item = navigation.attentionBanner, case .loaded(let worktrees) = state,
               projects(for: worktrees).contains(where: { $0.id == item.projectID }) {
                SidebarAttentionBanner(item: item,
                    project: projects(for: worktrees).first { $0.id == item.projectID },
                    projectIconData: projectIcons[item.projectID], onOpen: {
                        Task { await openReportTarget(item, worktrees: worktrees) }
                    }, onDismiss: { navigation.dismissAttentionBanner(item) })
                    .padding(10)
            }
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
                if horizontalSizeClass == .regular, !remoteMacConnections.isEmpty {
                    Button { showsRemoteMacManagement = true } label: {
                        Label("Remote Macs", systemImage: "server.rack")
                    }
                    .accessibilityLabel("Manage Remote Macs")
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
                    .navigationTitle("Remote Macs")
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
                includeRemoteWorktrees: includeRemoteWorktrees,
                remoteConnectionProvider: remoteConnectionProvider
            ) { response in
                Task { await handleCreated(response) }
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

    private func pollRemoteWorktrees() async {
        guard includeRemoteWorktrees, isReadyToLoad else { return }
        let requestHostID = host.id
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
                let list = try await fetchWorktrees(
                    host: host,
                    remoteSnapshotProvider: remoteSnapshotProvider,
                    includeRemoteWorktrees: true
                )
                guard Self.shouldApplyLoadResult(
                    requestHostID: requestHostID,
                    presentedHostID: presentedHostID,
                    isCancelled: Task.isCancelled
                ) else { return }
                applyLoadedList(list)
                // Sidebar-only changes (order, availability, and icons) may
                // arrive while the worktree array itself is unchanged.
                await updateNavigationMetadata(list, requestHostID: requestHostID)
            } catch is CancellationError {
                return
            } catch {
                // Keep the last usable list. The primary load/refresh
                // paths still surface transport errors to the user.
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
        guard horizontalSizeClass == .regular || !showsProjectRail || project?.id == navigation.selectedProjectID,
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
            Section("Remote Macs") {
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
        sidebarSnapshot?.projects ?? SidebarProjection.projects(worktrees)
    }

    @ViewBuilder
    private func navigationContent(_ live: [WorktreePanes]) -> some View {
        let worktrees = reportOrder?.orderedWorktrees(live) ?? live
        let liveProjects = projects(for: live)
        let projects = reportOrder?.orderedProjects(liveProjects) ?? liveProjects
        let activityCounts = SidebarActivityCounts(items: SidebarProjection.activity(live))
        let counts = SidebarActivityCounts(items: live.flatMap { navigation.worktreeContext($0).pending }).attentionByProject
        if horizontalSizeClass != .regular, let project {
            projectDetail(worktrees, projects: projects, projectID: project.id)
        } else if !showsProjectRail {
            VStack(spacing: 0) {
                TextField("Find any project or worktree", text: $navigation.query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
                pendingButton(worktrees, projectID: SidebarLayoutPolicy.projectFilter(
                    selectedID: navigation.selectedProjectID, showsProjectRail: showsProjectRail))
                worktreeList(worktrees.filter { navigation.worktreeContext($0).matches(query: navigation.query) })
            }
        } else if horizontalSizeClass == .regular {
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
            if let selected = projects.first(where: { $0.id == selectedProjectID }), !selected.isAvailable {
                Text("The owning Mac is offline.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Find any project or worktree", text: $navigation.query).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            pendingButton(worktrees, projectID: selectedProjectID)
            worktreeList(worktrees.filter {
                navigation.query.isEmpty ? SidebarProjection.projectID($0) == selectedProjectID
                    : navigation.worktreeContext($0).matches(query: navigation.query)
            })
        }
    }

    @ViewBuilder
    private func pendingButton(_ worktrees: [WorktreePanes], projectID: String?) -> some View {
        let count = MobilePaneAttention.pendingCount(worktrees: worktrees.filter {
            projectID == nil || SidebarProjection.projectID($0) == projectID
        }, currentWorktree: nil, navigation: navigation)
        if count > 0 {
            Button("\(count) pending") {
                guard let item = navigation.nextPendingWorktree(in: displayedWorktrees(worktrees), projectID: projectID, after: selectedWorktreePath ?? projectID.flatMap { navigation.rememberedWorktrees[$0] }) else { return }
                Task { await openReportTarget(item, worktrees: worktrees) }
            }.font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
        }
    }

    private func displayedWorktrees(_ worktrees: [WorktreePanes]) -> [WorktreePanes] {
        MobilePaneAttention.displayedWorktrees(worktrees)
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
        if horizontalSizeClass == .regular, project.isAvailable {
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
                for _ in 0..<12 {
                    let list = try await fetchWorktrees(host: host, remoteSnapshotProvider: remoteSnapshotProvider, includeRemoteWorktrees: includeRemoteWorktrees)
                    guard presentedHostID == requestHostID, generation == selectionIntentGeneration else { return false }
                    applyLoadedList(list)
                    if let running = list.first(where: { $0.path == target.path && $0.layout != nil }) { target = running; break }
                    try await Task.sleep(for: .milliseconds(250))
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
                if let onSelectPaneWithWorktree { onSelectPaneWithWorktree(target, leaf) } else { onSelectPane(leaf) }
            } else if let onSelectWorktreeDetail { onSelectWorktreeDetail(target) }
            else { onSelect(target) }
            // The visit has occurred. A delayed acknowledgement must not consume
            // an unopened request or later replace a newer navigation choice.
            if includeRemoteWorktrees, let request = SidebarInteractionPolicy.acknowledgement(
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
            guard presentedHostID == requestHostID else { return false }
            showErrorToast("Couldn't open this request on the owning Mac.")
            return false
        }
    }

    static func shouldApplyNavigationSnapshot(_ snapshot: PanesStateMessage?, matching rows: [WorktreePanes]) -> Bool {
        guard case let .snapshot(snapshotRows, _)? = snapshot else { return false }
        return snapshotRows == rows
    }

    private func updateNavigationMetadata(_ list: [WorktreePanes], requestHostID: UUID) async {
        let snapshot: PanesStateMessage?
        if let remoteSidebarProvider { snapshot = await remoteSidebarProvider(list) }
        else { snapshot = .snapshot(list) }
        guard presentedHostID == requestHostID,
              Self.shouldApplyNavigationSnapshot(snapshot, matching: list),
              case let .snapshot(_, metadata)? = snapshot else { return }
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
                                                if let onSelectPaneWithWorktree {
                                                    onSelectPaneWithWorktree(wt, leaf)
                                                } else {
                                                    onSelectPane(leaf)
                                                }
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
                                            onClose: { if reportWorktreeID == wt.path { closeReport() } })
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

        do {
            let list = try await fetchWorktrees(
                host: host,
                remoteSnapshotProvider: remoteSnapshotProvider,
                includeRemoteWorktrees: includeRemoteWorktrees,
                onProgress: onProgress,
                reconnect: reconnect
            )
            guard Self.shouldApplyLoadResult(
                requestHostID: requestHostID,
                presentedHostID: presentedHostID,
                isCancelled: Task.isCancelled
            ) else { return }
            applyLoadedList(list)
            await updateNavigationMetadata(list, requestHostID: requestHostID)
        } catch is CancellationError {
            return
        } catch WorktreePanesFetcher.FetchError.forbidden {
            guard shouldApplyLoadFailure(requestHostID: requestHostID) else { return }
            applyRefreshFailure("Not authorized — is this device on your tailnet?")
        } catch WorktreePanesFetcher.FetchError.http(let code) {
            guard shouldApplyLoadFailure(requestHostID: requestHostID) else { return }
            applyRefreshFailure("HTTP \(code)")
        } catch WorktreePanesFetcher.FetchError.decode {
            guard shouldApplyLoadFailure(requestHostID: requestHostID) else { return }
            applyRefreshFailure(
                "The server sent a response this version can't read."
            )
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
    /// The authenticated panes subscription is sampled once per second, but
    /// most samples are identical. Suppressing those no-op writes keeps the
    /// live multi-pane hierarchy and its `SessionClient`s out of SwiftUI's
    /// update path until pane metadata or topology actually changes.
    private func applyLoadedList(_ list: [WorktreePanes]) {
        if let reportWorktreeID, !list.contains(where: { $0.path == reportWorktreeID }) { closeReport() }
        let next = LoadState.loaded(list)
        let changed = Self.shouldPublishLoadedList(
            current: state,
            next: list
        )
        loadedHostID = host.id
        refreshError = nil
        if changed {
            state = next
            onListChanged(list)
        }
    }

    static func shouldPublishLoadedList(
        current: LoadState,
        next: [WorktreePanes]
    ) -> Bool {
        current != .loaded(next)
    }

    private func fetchWorktrees(
        host: Host,
        remoteSnapshotProvider: RemoteWorktreeSnapshotProvider?,
        includeRemoteWorktrees: Bool,
        onProgress: RemoteWorktreeLoadProgress? = nil,
        reconnect: Bool = false
    ) async throws -> [WorktreePanes] {
        if let remoteSnapshotProvider {
            return try await remoteSnapshotProvider(onProgress, reconnect)
        }
        if onProgress != nil {
            loadingStage = .waitingForSnapshot
        }
        return try await WorktreePanesFetcher.fetch(
            baseURL: host.baseURL,
            includeRemoteWorktrees: includeRemoteWorktrees
        )
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

    private func acknowledgeViewedStop(_ worktree: WorktreePanes) {
        if let stop = SidebarProjection.activity([worktree]).first(where: { $0.agentStop != nil }) {
            navigation.opened(stop)
        }
        guard includeRemoteWorktrees,
              projects(for: [worktree]).first(where: { $0.id == SidebarProjection.projectID(worktree) })?.supportsWorktreeEditing == true,
              let request = SidebarInteractionPolicy.stoppedTurnAcknowledgement(for: worktree) else { return }
        let provider: RemoteConnectionProvider? = remoteConnectionProvider
        let requestHostID = host.id
        Task {
            do {
                let response = try await RelayedWorktreeManagementClient.send(request, using: provider)
                guard presentedHostID == requestHostID else { return }
                if case .error(let code, _, _, _) = response, code != "occurrence-changed" {
                    showErrorToast("Couldn't mark this agent stop as viewed.")
                }
            } catch {
                guard presentedHostID == requestHostID else { return }
                showErrorToast("Couldn't mark this agent stop as viewed.")
            }
        }
    }

    private func acknowledgeViewedPane(_ worktree: WorktreePanes, leaf: PaneLayoutNode.Leaf) {
        let context = navigation.worktreeContext(worktree)
        let items = context.pending.filter { $0.paneID == leaf.sessionName || $0.agentStop != nil }
        let supportsExact = projects(for: [worktree]).first { $0.id == context.item.projectID }?.supportsWorktreeEditing == true
        for item in items {
            navigation.opened(item)
            guard includeRemoteWorktrees,
                  let request = SidebarInteractionPolicy.acknowledgement(for: item, supportsExactAcknowledgement: supportsExact) else { continue }
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
                acknowledgeViewedStop(worktree)
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

            for attempt in 0..<12 {
                let list = try await fetchWorktrees(
                    host: selectionHost,
                    remoteSnapshotProvider: remoteSnapshotProvider,
                    includeRemoteWorktrees: includeRemoteWorktrees
                )
                guard !Task.isCancelled, selectionIsCurrent() else { return }
                state = .loaded(list)
                onListChanged(list)
                if let opened = list.first(where: {
                    $0.path == worktree.path
                        && $0.state == .running
                        && $0.layout != nil
                }) {
                    if selectionIsCurrent() {
                        onSelect(opened)
                        acknowledgeViewedStop(opened)
                    }
                    return
                }
                guard attempt < 11 else { break }
                try await Task.sleep(for: .milliseconds(250))
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

    /// Re-fetch without blanking the existing list so the user isn't
    /// shown a spinner over a list they just saw populated.
    private func handleCreated(_ response: CreateWorktreeClient.Response) async {
        for attempt in 0..<5 {
            await refresh()
            guard case .loaded(let list) = state else { return }
            if let match = list.first(where: {
                $0.path == response.worktreePath
            }) {
                onSelect(match)
                return
            }
            guard attempt < 4 else { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Issue the delete request; on success refresh in place, on
    /// forceable failure surface the Force Delete confirmation, on
    /// any other failure surface a transient error toast.
    private func performDelete(worktree: WorktreePanes, force: Bool) async {
        let requestContext = DeleteRequestContext(
            hostID: host.id,
            baseURL: host.baseURL,
            remoteConnectionProvider: remoteConnectionProvider
        )
        do {
            if requestContext.remoteConnectionProvider != nil {
                let response = try await RelayedWorktreeManagementClient.send(
                    .delete(worktreeID: worktree.path, force: force),
                    using: requestContext.remoteConnectionProvider
                )
                guard case .deleted = response else {
                    handleRemoteDeleteResponse(
                        response,
                        worktreePath: worktree.path,
                        requestContext: requestContext
                    )
                    return
                }
            } else {
                _ = try await DeleteWorktreeClient.delete(
                    baseURL: requestContext.baseURL,
                    body: DeleteWorktreeClient.Request(
                        worktreePath: worktree.path,
                        force: force
                    )
                )
            }
            await refresh()
        } catch let DeleteWorktreeClient.DeleteError.gitFailedForceable(stderr, status) {
            pendingForceDelete = PendingForceDelete(
                worktreePath: worktree.path,
                stderr: stderr,
                shortStatus: status,
                requestContext: requestContext
            )
        } catch let error as DeleteWorktreeClient.DeleteError {
            surfaceDeleteError(error)
        } catch {
            showErrorToast("Couldn't reach the server.")
        }
    }

    /// User confirmed Force Delete on a 409 forceable response —
    /// re-issue with `force: true`.
    private func performForceDelete(_ pending: PendingForceDelete) async {
        do {
            if pending.requestContext.remoteConnectionProvider != nil {
                let response = try await RelayedWorktreeManagementClient.send(
                    .delete(worktreeID: pending.worktreePath, force: true),
                    using: pending.requestContext.remoteConnectionProvider
                )
                guard case .deleted = response else {
                    handleRemoteDeleteResponse(
                        response,
                        worktreePath: pending.worktreePath,
                        requestContext: pending.requestContext
                    )
                    return
                }
            } else {
                _ = try await DeleteWorktreeClient.delete(
                    baseURL: pending.requestContext.baseURL,
                    body: DeleteWorktreeClient.Request(
                        worktreePath: pending.worktreePath,
                        force: true
                    )
                )
            }
            await refresh()
        } catch let error as DeleteWorktreeClient.DeleteError {
            surfaceDeleteError(error)
        } catch {
            showErrorToast("Couldn't reach the server.")
        }
    }

    /// Surface an error after a delete attempt. Toasts the user-facing
    /// message and re-fetches only when the list actually changed
    /// server-side (`.notFound` means the row vanished between the
    /// picker render and the delete request).
    private func surfaceDeleteError(_ error: DeleteWorktreeClient.DeleteError) {
        if let msg = error.userMessage {
            showErrorToast(msg)
        }
        if case .notFound = error {
            Task { await refresh() }
        }
    }

    private func handleRemoteDeleteResponse(
        _ response: WorktreeManagementResponse,
        worktreePath: String,
        requestContext: DeleteRequestContext
    ) {
        if case let .error(_, message, forceAllowed, shortStatus) = response {
            if forceAllowed {
                pendingForceDelete = PendingForceDelete(
                    worktreePath: worktreePath,
                    stderr: message,
                    shortStatus: shortStatus ?? "",
                    requestContext: requestContext
                )
            } else {
                showErrorToast(message)
            }
        } else {
            showErrorToast("The remote Mac returned an unexpected response.")
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

private struct RemotePollingKey: Hashable {
    let hostID: UUID
    let enabled: Bool
    let isReady: Bool
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

struct RemoteMacConnectionRow: View {
    let remoteMac: RemoteMacConnectionSummary
    let isReconnecting: Bool
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: remoteMac.state.mobileSystemImage)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(remoteMac.label)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isReconnecting || remoteMac.state == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting to \(remoteMac.label)")
            } else if remoteMac.state.mobileCanReconnect {
                Button(remoteMac.state.mobileReconnectLabel) {
                    onReconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(
                    "\(remoteMac.state.mobileReconnectLabel) to \(remoteMac.label)"
                )
            }
        }
    }

    private var subtitle: String {
        [remoteMac.lastKnownHost, remoteMac.state.mobileStatusText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var iconColor: Color {
        switch remoteMac.state {
        case .connected, .discovered:
            .green
        case .connecting:
            .accentColor
        case .failed, .needsPairing:
            .orange
        case .offline:
            .secondary
        }
    }
}

extension RemoteMacConnectionSummary.State {
    var mobileSystemImage: String {
        switch self {
        case .offline: "laptopcomputer"
        case .discovered: "wifi"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .needsPairing: "key"
        }
    }

    var mobileStatusText: String {
        switch self {
        case .offline: "Offline"
        case .discovered: "Available"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .failed: "Connection failed"
        case .needsPairing: "Pair again on the connected Mac"
        }
    }

    var mobileCanReconnect: Bool {
        self != .connecting && self != .needsPairing
    }

    var mobileReconnectLabel: String {
        self == .discovered ? "Connect" : "Reconnect"
    }
}

struct WorktreeBlock: View {
    @Environment(\.editMode) private var editMode
    let worktree: WorktreePanes
    var project: SidebarProject? = nil
    var projectIconData: Data? = nil
    let theme: GhosttyThemeColors?
    /// True when this worktree's path matches `selectedWorktreePath`
    /// (IPAD-1.16). Drives both the rounded-rectangle background
    /// highlight on the whole block and the active brightness bucket
    /// for pane rows beneath it.
    let isActive: Bool
    let isOpening: Bool
    /// Session name of the focused pane within `appState`. Each pane
    /// row tests `leaf.sessionName == focusedPaneId` to decide whether
    /// to use the brightest focused bucket from `theme.paneTitle(…)`.
    let focusedPaneId: String?
    var projectColumn: Bool = false
    let context: SidebarWorktreeContext
    let onSelect: () -> Void
    let onSelectPane: (PaneLayoutNode.Leaf) -> Void
    let onReport: () -> Void

    var body: some View {
        // IPAD-1.13: pack the worktree row + its pane rows into a
        // single List row via a tight VStack so the iOS sidebar-list
        // style's default per-row padding doesn't compound between
        // panes. A small 3pt inter-row spacing gives breathing room
        // between consecutive pane rows without re-inflating to the
        // sidebar-style's full per-row padding.
        VStack(alignment: .leading, spacing: 3) {
            worktreeRow
            paneRows
        }
        // IPAD-1.16: active-worktree block highlight (Mac parity).
        // Painted on the whole VStack so the rounded rectangle spans
        // both the worktree row and its pane children — same visual
        // grouping as the Mac sidebar's `worktreeBlock`.
        .padding(.leading, projectColumn ? 8 : 6)
        .padding(.trailing, projectColumn ? 8 : 2)
        .padding(.vertical, projectColumn ? 0 : 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlightFill)
        )
        .listRowInsets(EdgeInsets(
            top: projectColumn ? 0 : 4,
            leading: projectColumn ? 6 : WorktreeListContent.iPadRowLeadingInset,
            bottom: projectColumn ? 0 : 4,
            trailing: projectColumn ? 6 : WorktreeListContent.iPadRowTrailingInset
        ))
        .listRowSeparator(.hidden)
        .moveDisabled(editMode?.wrappedValue.isEditing != true)
    }

    /// Themed active-worktree fill when available, else `.clear`. The
    /// 0.16 alpha matches the Mac sidebar's chosen contrast on top of
    /// `theme.sidebarBackground`.
    private var highlightFill: Color {
        guard isActive else { return .clear }
        if let theme {
            return theme.foreground.opacity(0.16)
        }
        return Color.primary.opacity(0.12)
    }

    @ViewBuilder
    private var worktreeRow: some View {
        if worktree.state.isInFlight {
            // Non-tappable: on-disk path may not exist yet
            // (`.creating`) or is about to vanish (`.deleting`).
            HStack(spacing: 0) {
                rowIdentity
                DivergenceGutter(stats: worktree.stats, theme: theme)
            }
        } else {
            HStack(spacing: 0) {
                MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) { rowIdentity }
                MobileWorktreeReportButton(worktreeName: worktree.displayName, onReport: onReport)
                    .disabled(editMode?.wrappedValue.isEditing == true)
                MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) {
                    DivergenceGutter(stats: worktree.stats, theme: theme)
                        .frame(minHeight: 44)
                }
            }
            .disabled(isOpening)
        }
    }

    private var rowIdentity: some View {
        WorktreeRowContent(worktree: worktree, project: project, projectIconData: projectIconData,
            theme: theme, isActive: isActive, isOpening: isOpening,
            attentionCount: MobileWorktreeRowPresentation(context: context).worktreeAttentionCount)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var paneRows: some View {
        let presentation = MobileWorktreeRowPresentation(context: context)
        ForEach(Array(presentation.leaves.enumerated()), id: \.element.sessionName) { index, leaf in
            let isQuestionPane = presentation.questionPaneID == leaf.sessionName
            let effective = leaf.attentionText ?? (index == 0 ? worktree.attentionText : nil)
            let style = isQuestionPane ? nil : effective.map {
                AttentionCapsuleStyle.from(text: $0, source: leaf.attentionText != nil ? leaf.attentionSource : worktree.attentionSource)
            }
            MobileWorktreeReportTarget(onOpen: { onSelectPane(leaf) }, onReport: onReport) {
                VStack(alignment: .leading, spacing: 4) {
                    PaneTitleRow(leaf: leaf, theme: theme, attentionStyle: style,
                        isFocusedPane: leaf.sessionName == focusedPaneId, isActiveWorktree: isActive,
                        attentionCount: context.pending.filter { $0.paneID == leaf.sessionName || ($0.paneID == nil && index == 0) }.count)
                    if isQuestionPane {
                        SidebarWorktreeQuestion(context: context)
                            .padding(.leading, SidebarPaneLayout.markerLeading + SidebarPaneLayout.markerSpacing)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if presentation.showsWorktreeQuestion {
            MobileWorktreeReportTarget(onOpen: onSelect, onReport: onReport) {
                SidebarWorktreeQuestion(context: context)
                    .padding(.leading, SidebarPaneLayout.markerLeading + SidebarPaneLayout.markerSpacing)
            }
        }
    }

}

/// Wrap a themed `Color` in an `AnyShapeStyle`, falling back to the
/// system `.secondary` style when no theme is supplied. Used by the row
/// helpers below so each row site doesn't re-spell the same `if let`.
private func themedOrSecondary(_ themed: Color?) -> AnyShapeStyle {
    themed.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
}

/// Type icon + optional PR badge + display name (italic for main
/// checkout, strikethrough when stale), optional secondary branch
/// label stacked beneath the display name when present (IPAD-1.15).
private struct WorktreeRowContent: View {
    let worktree: WorktreePanes
    var project: SidebarProject? = nil
    var projectIconData: Data? = nil
    let theme: GhosttyThemeColors?
    /// True when this worktree is the active one — drives the primary
    /// label's brightness bucket via `theme.sidebarPrimaryText
    /// (isActive: …)` so the selected row reads brighter than its
    /// siblings (IPAD-1.16).
    let isActive: Bool
    let isOpening: Bool
    let attentionCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SidebarActivityBadge(attentionCount)
            typeIcon
            if let badge = worktree.prBadge {
                SidebarPRBadge(badge: badge)
                    .fixedSize()
            }
            // IPAD-1.15: the branch label gets its own line beneath
            // the worktree's display name rather than running inline.
            // Two-line stack keeps long names + long branches from
            // squishing each other or pushing the divergence gutter
            // off the trailing edge at narrow sidebar widths.
            VStack(alignment: .leading, spacing: 1) {
                primaryText
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let secondary = secondaryBranch {
                    Text(secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(themedOrSecondary(theme?.sidebarSecondaryText))
                }
            }
            // IPAD-1.14: worktree-scoped attentionText is rendered on
            // the first pane row (see WorktreeBlock.paneRows), not
            // here — "needs input" pills always sit on pane rows.
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var typeIcon: some View {
        if worktree.state.isInFlight || isOpening {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14)
        } else if worktree.iconIdentity != .none {
            WorktreeIdentityView(identity: worktree.iconIdentity,
                project: project ?? SidebarProjection.projects([worktree])[0],
                imageData: projectIconData, size: 18)
        } else {
            Image(systemName: WorktreeRowIcon.symbolName(
                isMainCheckout: worktree.isMainCheckout,
                hasPR: worktree.prBadge != nil
            ))
            .font(.system(size: 11))
            .foregroundStyle(typeIconStyle)
            .frame(width: 14)
        }
    }

    /// Themed dim for closed/creating/deleting (falls back to system
    /// `.secondary` when no theme is supplied — i.e., compact iPhone
    /// path), green when running, yellow when stale. The themed path
    /// goes through the shared `GhosttyThemeColors.worktreeStateIcon`
    /// accessor so the Mac sidebar uses identical state-to-color
    /// mapping.
    private var typeIconStyle: AnyShapeStyle {
        if let theme {
            return AnyShapeStyle(theme.worktreeStateIcon(worktree.state))
        }
        // No-theme (compact iPhone) path: keep the system `.secondary`
        // dim for inactive states so the row reads against the system
        // grouped-list background.
        switch worktree.state {
        case .closed, .creating, .deleting: return AnyShapeStyle(.secondary)
        case .running: return AnyShapeStyle(Color.green)
        case .stale: return AnyShapeStyle(Color.yellow)
        }
    }

    @ViewBuilder
    private var primaryText: some View {
        let primary = theme?.sidebarPrimaryText(isActive: isActive)
        if worktree.state == .stale {
            Text(worktree.displayName)
                .strikethrough()
                .foregroundStyle(themedOrSecondary(theme?.sidebarStaleText))
        } else if worktree.isMainCheckout {
            Text(worktree.displayName)
                .italic()
                .foregroundColor(primary)
        } else {
            Text(worktree.displayName)
                .foregroundColor(primary)
        }
    }

    /// Skip the dim branch label when it duplicates the primary
    /// display name — showing both is noise.
    private var secondaryBranch: String? {
        let branch = worktree.displayBranch
        guard !branch.isEmpty, branch != worktree.displayName else { return nil }
        return branch
    }
}

/// Pane child row: `↳` glyph + caption-sized title. When the pane has
/// a shell-integration ping (or the caller has attached the
/// worktree-scoped `attentionText` here per IPAD-1.14), an attention
/// capsule renders to the *right* of the title — not in place of it —
/// truncating the title to make room (LAYOUT-2.30).
private struct PaneTitleRow: View {
    let leaf: PaneLayoutNode.Leaf
    let theme: GhosttyThemeColors?
    /// The attention capsule this pane row should display (agent-stop icon,
    /// or notify/✓! text), or nil. Normally derived from `leaf`, but the
    /// first pane in a worktree also inherits the worktree-scoped ping as a
    /// fallback so "needs input" always lives on a pane row.
    let attentionStyle: AttentionCapsuleStyle?
    /// True when this leaf is the currently-focused pane. Drives the
    /// brightest bucket on `theme.paneArrow` and `theme.paneTitle`
    /// (IPAD-1.16), and bolds the arrow + title — matching the Mac
    /// sidebar's focused-pane treatment.
    let isFocusedPane: Bool
    /// True when this leaf's worktree is the active one. Drives the
    /// middle bucket on the brightness ladders so non-focused panes
    /// inside the active worktree still read brighter than panes in
    /// other worktrees.
    let isActiveWorktree: Bool
    var attentionCount: Int = 0

    var body: some View {
        // Busy style applies only when no capsule is shown — a needs-input
        // ping (claude waiting) supersedes "working". Shared with the Mac
        // row via PaneTitleBusyStyle so the precedence rule can't drift.
        let busyStyle = PaneTitleBusyStyle.applies(
            isBusy: leaf.isBusy, hasAttentionCapsule: attentionStyle != nil)
        // LAYOUT-2.31: the agent "needs input" state colors the title red
        // (alongside the red icon) so it's scannable.
        let isNeedsInput: Bool = {
            if case .needsInput = attentionStyle { return true }
            return false
        }()
        HStack(spacing: SidebarPaneLayout.markerSpacing) {
            SidebarPaneMarker(
                attentionCount: attentionCount,
                isFocused: isFocusedPane,
                arrowColor: theme?.paneArrow(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree
                ) ?? .secondary
            )
            // LAYOUT-2.30: title (truncates) then pill (intrinsic width).
            // AGENT-2.2: a busy pane renders its title in italic. Apply it
            // at the Text level (Text.italic()) so it composes with the
            // focused pane's `.semibold`; the View-level `.italic(_:)`
            // modifier is dropped when a Text-level fontWeight is set.
            let titleBase = Text(leaf.displayTitle)
                .font(.caption)
                .fontWeight(isFocusedPane ? .semibold : .regular)
            (busyStyle ? titleBase.italic() : titleBase)
                .foregroundStyle(isNeedsInput ? AnyShapeStyle(.red) : themedOrSecondary(theme?.paneTitle(
                    isFocusedPane: isFocusedPane,
                    isActiveWorktree: isActiveWorktree,
                    // Use the raw title (not displayTitle, which falls back
                    // to a non-empty "shell"): an unset title should hit the
                    // dimmer placeholder bucket, matching the Mac sidebar.
                    hasTitle: !leaf.title.isEmpty
                )))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            if let attentionStyle {
                AttentionCapsule(style: attentionStyle)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SidebarPaneLayout.markerLeading)
    }
}

/// Red status pill — worktree row uses it for CLI `graftty notify`
/// pings; pane row uses it for shell-integration pings.
private struct AttentionCapsule: View {
    let style: AttentionCapsuleStyle

    var body: some View {
        switch style {
        case let .needsInput(label):
            // Agent "needs input" is a bare red icon (no pill); text kept
            // for accessibility.
            Image(systemName: AttentionCapsuleStyle.needsInputSymbol)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
                .accessibilityLabel(label)
        case let .text(text):
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
    }
}

/// Trailing `↑X[+] ↓Y` indicator. Ahead side gets a `+` suffix when
/// there are uncommitted changes so a clean-but-dirty branch still
/// surfaces; behind side renders in red.
private struct DivergenceGutter: View {
    let stats: WorktreeWireStats?
    let theme: GhosttyThemeColors?

    var body: some View {
        if let stats, !stats.isEmpty {
            commitsText(stats)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private func commitsText(_ s: WorktreeWireStats) -> Text {
        let aheadShown = s.ahead > 0 || s.hasUncommittedChanges
        let behindShown = s.behind > 0
        // Themed dim when available; nil leaves it on the system label
        // color which the surrounding default-foreground tree already
        // dims for `.foregroundColor(.secondary)` on the compact path.
        let ahead = Text("↑\(s.ahead)\(s.hasUncommittedChanges ? "+" : "")")
            .foregroundColor(theme?.sidebarSecondaryText ?? .secondary)
        let behind = Text("↓\(s.behind)")
            .foregroundColor(.red)
        if aheadShown && behindShown { return ahead + Text(" ") + behind }
        if aheadShown { return ahead }
        return behind
    }
}

struct WorktreeLoadingView: View {
    static let detailRevealDelay: Duration = .milliseconds(750)

    let hostLabel: String
    let stage: RemoteWorktreeLoadStage

    @State private var startedAt = Date()
    @State private var detailsVisible = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading worktrees…")
                .foregroundStyle(.secondary)

            if detailsVisible {
                VStack(spacing: 3) {
                    Text(Self.detail(for: stage, hostLabel: hostLabel))
                    TimelineView(.periodic(from: startedAt, by: 1)) {
                        context in
                        Text(Self.elapsedText(
                            startedAt: startedAt,
                            now: context.date
                        ))
                        .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .task {
            do {
                try await Task.sleep(for: Self.detailRevealDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                detailsVisible = true
            }
        }
    }

    static func detail(
        for stage: RemoteWorktreeLoadStage,
        hostLabel: String
    ) -> String {
        switch stage {
        case .connecting:
            return "Connecting securely to \(hostLabel)…"
        case .openingChannel:
            return "Opening secure worktree channel…"
        case .waitingForSnapshot:
            return "Waiting for worktree list…"
        }
    }

    static func elapsedText(startedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return "Elapsed \(seconds)s"
    }
}
#endif
