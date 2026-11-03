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

    @State private var isAddSheetPresented: Bool = false
    @State private var pendingDelete: PendingDelete?
    @State private var pendingForceDelete: PendingForceDelete?
    @State private var errorToast: String?
    @State private var errorToastTask: Task<Void, Never>?
    @State private var openingWorktrees: Set<OpeningWorktreeKey> = []
    @State private var selectionIntentGeneration: UInt64 = 0
    @State private var worktreeCreation = MobileWorktreeCreation()

    @Bindable private var navigation: SidebarNavigationState
    @State private var collapsedPinned: [String: Bool] = [:]
    @State private var collapsedFolders: Set<String> = []
    @State private var wakeFailure: WakeFailure?
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
    private var navigationWindowWidth: Double

    private struct PendingDelete: Identifiable, Equatable {
        let id = UUID()
        let worktree: WorktreePanes
        let action: WorktreePickerSwipeAction
    }

    private struct DeleteRequestContext {
        let host: Host
        let remoteConnectionProvider: RemoteConnectionProvider?
    }

    private struct PendingForceDelete: Identifiable {
        let id = UUID()
        let worktreePath: String
        let stderr: String
        let shortStatus: String
        let requestContext: DeleteRequestContext
    }

    private struct WakeFailure: Identifiable {
        let id = UUID()
        let worktree: WorktreePanes
        let host: Host
    }

    private struct OpeningWorktreeKey: Hashable {
        let hostID: UUID?
        let path: String
    }

    public let feed: MultiHostFeed
    /// A compact navigation destination, independent of shared sidebar selection.
    let project: SidebarProject?
    /// Ghostty palette for theming row text. nil keeps the system colors
    /// in use on the compact (iPhone) path, where the List renders against
    /// the standard grouped-list background; the iPad sidebar paints a
    /// themed background so it supplies a non-nil theme here.
    public let theme: GhosttyThemeColors?
    /// The selected worktree. A path alone can repeat across hosts.
    public let selectedHostID: UUID?
    public let selectedWorktreePath: String?
    /// Waits for the scene to be active and the biometric gate to open.
    public let isReadyToLoad: Bool
    public let onSelect: (Host, WorktreePanes) -> Void
    public let onSelectPane: (Host, WorktreePanes, PaneLayoutNode.Leaf) -> Void
    private let onSelectWorktreeDetail: ((Host, WorktreePanes) -> Void)?

    public init(
        feed: MultiHostFeed,
        isSidebar: Bool = false,
        theme: GhosttyThemeColors? = nil,
        selectedHostID: UUID? = nil,
        selectedWorktreePath: String? = nil,
        isReadyToLoad: Bool = true,
        onSelect: @escaping (Host, WorktreePanes) -> Void,
        onSelectPane: @escaping (Host, WorktreePanes, PaneLayoutNode.Leaf) -> Void,
        navigation: SidebarNavigationState? = nil,
        navigationWindowWidth: Double = 1100,
        project: SidebarProject? = nil,
        onSelectWorktreeDetail: ((Host, WorktreePanes) -> Void)? = nil
    ) {
        self.feed = feed
        self.isSidebar = isSidebar
        self.project = project
        self.theme = theme
        self.selectedHostID = selectedHostID
        self.selectedWorktreePath = selectedWorktreePath
        self.isReadyToLoad = isReadyToLoad
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
        self.onSelectWorktreeDetail = onSelectWorktreeDetail
        self.navigation = navigation ?? SidebarNavigationState(prefix: "sidebar.mobile", collapsed: true)
        self.navigationWindowWidth = navigationWindowWidth
    }

    private var merged: SidebarMergedRows { feed.state.merged(localDeviceID: nil) }

    private var selectedMergedID: String? {
        merged.selectedProjectID(for: navigation.selectedProjectID)
    }

    private var state: LoadState {
        let rows = feed.state.rows
        if !rows.isEmpty || feed.hasSettled {
            if rows.isEmpty, !feed.hosts.isEmpty, feed.hosts.allSatisfy({ !feed.state.isLive($0.id) }) {
                return .error("None of your paired hosts could be reached.")
            }
            return .loaded(rows)
        }
        return .loading
    }

    /// The row's own host, and how to reach it: a relayed row's path means
    /// nothing to any other host.
    private func route(for worktree: WorktreePanes) -> (host: Host, provider: RemoteConnectionProvider)? {
        feed.host(for: worktree).map { ($0, feed.provider(for: $0)) }
    }

    private func isSelected(_ worktree: WorktreePanes) -> Bool {
        worktree.path == selectedWorktreePath && feed.state.hostID(for: worktree) == selectedHostID
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
        .onChange(of: feed.state) { _, _ in rowsChanged() }
        .task(id: selectedMergedID) { syncNavigation() }
        .task(id: PendingWorktreeRouteKey(item: MobilePaneAttention.pendingRoute(for: navigation), loaded: isLoaded)) {
            consumePendingWorktreeRoute()
        }
        .onChange(of: selectedWorktreePath) { _, path in
            selectionIntentGeneration &+= 1
            if path != nil, case .loaded(let rows) = state, let worktree = rows.first(where: isSelected) {
                rememberWorktree(worktree)
            }
        }
        .onChange(of: navigation.query) { _, _ in closeReport() }
        .onChange(of: navigation.selectedProjectID) { _, _ in closeReport() }
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
                // Fills the column: the sidebar's measured width is persisted.
                WorktreeLoadingView(hostLabel: feed.hosts.first?.label ?? "", stage: .connecting)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let msg):
                ContentUnavailableView {
                    Label("Couldn't load worktrees", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Retry") { Task { await feed.refresh() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded(let worktrees):
                navigationContent(worktreeCreation.rows(in: worktrees))
            }
        }
    }

    private var presentedContent: some View {
        loadContent
        .onChange(of: showsProjectRail) { _, _ in
            selectionIntentGeneration &+= 1
            navigation.resetSelection()
        }
        .alert(wakeFailure.map { "\($0.host.label) didn't respond." } ?? "", isPresented: Binding(
            get: { wakeFailure != nil }, set: { if !$0 { wakeFailure = nil } }
        ), presenting: wakeFailure) { failure in
            Button("Try Again") { wakeAndOpen(failure.worktree, on: failure.host) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Waking only works on its local network.")
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
                    pendingForceDelete != nil
                },
                set: { if !$0 { pendingForceDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingForceDelete
        ) { pending in
            Button("Force Delete", role: .destructive) {
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
        // The caller owns the title: the compact path sets one for its push,
        // and the iPad sidebar shows none (IPAD-1.2).
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isAddSheetPresented = true
                } label: {
                    Label("Add Worktree", systemImage: "plus")
                }
                .accessibilityLabel("Add Worktree")
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddWorktreeSheetView(targets: addWorktreeTargets, initialProjectID: project?.id ?? (isSidebar ? selectedMergedID : nil)) { submission in
                beginCreatingWorktree(submission)
            }
        }
    }

    private var addWorktreeTargets: [AddWorktreeSheetView.Target] {
        merged.projects.compactMap { project in
            let routes = project.members.compactMap { member -> AddWorktreeSheetView.Route? in
                guard let host = feed.host(for: member) else { return nil }
                return AddWorktreeSheetView.Route(
                    choice: AddWorktreeHostChoice(id: member.id, host: member.owner?.deviceLabel ?? host.label,
                        path: (member.owner?.relayDepth ?? 0) == 0 ? member.repositoryID : nil,
                        availability: merged.availability(ofMember: member.id)),
                    host: host, provider: feed.provider(for: host), repositoryID: member.repositoryID)
            }
            guard !routes.isEmpty else { return nil }
            return AddWorktreeSheetView.Target(id: project.id, name: project.name, routes: routes)
        }
    }

    /// Keeps saved reports, cards and icons in step with what hosts report.
    private func syncNavigation() {
        let rows = feed.state.rows
        let merged = merged
        navigation.reconcile(worktrees: rows, projects: feed.state.projects)
        if selectedMergedID == nil {
            navigation.selectedProjectID = rows.first(where: isSelected).map { merged.mergedID(forMember: SidebarProjection.projectID($0)) }
        } else if navigation.selectedProjectID != selectedMergedID {
            navigation.selectedProjectID = selectedMergedID
        }
        let members = merged.projects.compactMap(\.iconMember)
        projectIconCache.reconcile(members)
        for member in members where merged.availability(ofMember: member.id) == .reachable {
            guard let revision = member.iconRevision, let host = feed.host(for: member) else { continue }
            let provider = feed.provider(for: host)
            Task { await projectIconCache.load(for: member) {
                let response = try? await RelayedWorktreeManagementClient.send(
                    .projectIcon(repositoryID: member.repositoryID, revision: revision), using: provider)
                if case .icon(let data) = response { return data }
                return nil
            } }
        }
    }

    private func rowsChanged() {
        let list = feed.state.rows
        if let reportWorktreeID, !list.contains(where: { $0.path == reportWorktreeID }) { closeReport() }
        syncNavigation()
        if let created = worktreeCreation.takeReadySelection(in: list, generation: selectionIntentGeneration) {
            rememberWorktree(created)
            if let host = feed.host(for: created) { onSelect(host, created) }
        }
    }

    private func rememberWorktree(_ worktree: WorktreePanes) {
        let id = merged.mergedID(forMember: SidebarProjection.projectID(worktree))
        navigation.rememberedWorktrees[id] = MergedWorktreeList.identity(worktree)
        navigation.selectedProjectID = id
    }

    private func consumePendingWorktreeRoute() {
        guard isSidebar || !showsProjectRail || project?.id == selectedMergedID,
              let item = MobilePaneAttention.pendingRoute(for: navigation),
              case .loaded(let rows) = state,
              rows.contains(where: { $0.path == item.worktreeID && SidebarProjection.projectID($0) == item.projectID }) else { return }
        MobilePaneAttention.consumePendingRoute(for: navigation)
        // Consuming the route changes the task identity. Keep opening outside
        // that task so its cancellation cannot interrupt navigation.
        Task { await openReportTarget(item, worktrees: rows) }
    }

    @ViewBuilder
    private func navigationContent(_ live: [WorktreePanes]) -> some View {
        let merged = merged
        let worktrees = reportOrder?.orderedWorktrees(live) ?? live
        let projects = merged.projects.map(\.representative)
        let activityCounts = SidebarActivityCounts(items: SidebarProjection.activity(live))
        let working = merged.rekeyed(activityCounts.workingByProject)
        let counts = merged.rekeyed(SidebarActivityCounts(items: live.flatMap { navigation.worktreeContext($0).pending }).attentionByProject)
        let icons = mergedIcons(merged)
        if !isSidebar, let project {
            projectDetail(worktrees, merged: merged, projectID: project.id)
        } else if !showsProjectRail {
            VStack(spacing: 0) {
                TextField("Find any project or worktree", text: $navigation.query)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
                worktreeList(worktrees, merged: merged, projectIDs: merged.projects.map(\.id))
            }
        } else if isSidebar {
            HStack(spacing: 0) {
                ProjectNavigationRail(projects: projects, counts: counts, workingCounts: working, icons: icons,
                                      selectedID: selectedMergedID,
                                      collapsed: Binding(get: {
                    SidebarLayoutPolicy.railCollapsed(preference: navigation.railCollapsed, isMobile: true, windowWidth: navigationWindowWidth)
                }, set: { navigation.railCollapsed = $0 }),
                                      expandedWidth: $navigation.railExpandedWidth,
                                      allowsReordering: !orderMutationInFlight,
                                      canExpand: navigationWindowWidth >= 1100,
                                      selectionColor: theme?.foreground.opacity(0.16) ?? .primary.opacity(0.12),
                                      onSelect: { project in selectProject(project, worktrees: worktrees) },
                                      onMove: moveProject)
                Divider()
                projectDetail(worktrees, merged: merged)
                    .frame(minWidth: 220, maxWidth: .infinity)
            }
        } else {
            List {
                pendingCreationRows()
                ForEach(projects) { project in
                    NavigationLink(value: ProjectStep(project: project)) {
                        HStack(spacing: 10) {
                            ProjectIdentityView(project: project, imageData: icons[project.id])
                            Text(project.name)
                            Spacer()
                            if let status = project.ownerSubtitle(localDeviceID: nil) { Text(status).font(.caption) }
                            HStack(spacing: 4) {
                                SidebarActivityBadge(working[project.id, default: 0], kind: .working)
                                SidebarActivityBadge(counts[project.id, default: 0])
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.onMove { offsets, destination in
                    guard let source = offsets.first, source != destination, source + 1 != destination else { return }
                    let target = destination > source ? destination - 1 : destination
                    guard projects.indices.contains(target) else { return }
                    moveProject(projects[source].id, projects[target].id, destination > source)
                }.moveDisabled(orderMutationInFlight)
            }.toolbar { EditButton() }
        }
    }

    private func mergedIcons(_ merged: SidebarMergedRows) -> [String: Data] {
        var result: [String: Data] = [:]
        for project in merged.projects {
            if let member = project.iconMember { result[project.id] = projectIcons[member.id] }
        }
        return result
    }

    private func projectDetail(_ worktrees: [WorktreePanes], merged: SidebarMergedRows, projectID: String? = nil) -> some View {
        let selectedProjectID = projectID ?? selectedMergedID
        return VStack(spacing: 0) {
            if !isSidebar {
                pendingCreationRows(excludingProjectID: selectedProjectID)
                    .padding(.horizontal, 10)
            }
            if let selected = merged.project(id: selectedProjectID), !selected.representative.isAvailable {
                Text("Every host for this project is offline.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Find any project or worktree", text: $navigation.query).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            worktreeList(worktrees, merged: merged, projectIDs: selectedProjectID.map { [$0] } ?? [])
        }
    }

    /// Compact navigation may still show the project picker or another
    /// project's detail while the requested worktree is being created.
    private func pendingCreationRows(excludingProjectID: String? = nil) -> some View {
        let snapshot = feed.state.rows
        return ForEach(worktreeCreation.pendingRows(in: snapshot).filter {
            merged.mergedID(forMember: SidebarProjection.projectID($0)) != excludingProjectID
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

    private func moveProject(_ id: String, _ target: String, _ after: Bool) {
        let merged = merged
        let reachable: (SidebarProject) -> Bool = { merged.availability(ofMember: $0.id) == .reachable }
        let writes = merged.projectMove(id: id, target: target, after: after, changedAt: Date().timeIntervalSinceReferenceDate, isReachable: reachable)
        if !writes.isEmpty {
            performOrderMutations(writes.compactMap { write in
                feed.host(for: write.member).map { ($0, .setProjectRank(repositoryID: write.member.repositoryID, rank: write.rank, changedAt: write.changedAt)) }
            })
            return
        }
        guard let project = merged.project(id: id) else { return }
        // Every host for this project is asleep. A rank needs somewhere to be
        // stored, so wake one; it only moves once that host has it.
        if project.availability == .asleep, let member = project.members.first(where: { $0.rank != nil }), let host = feed.host(for: member) {
            Task { @MainActor in
                guard await feed.wake(host) else {
                    showErrorToast("\(host.label) didn't respond, so the project stayed in place.")
                    return
                }
                let writes = self.merged.projectMove(id: id, target: target, after: after, changedAt: Date().timeIntervalSinceReferenceDate, isReachable: { $0.id == member.id })
                performOrderMutations(writes.map { (host, .setProjectRank(repositoryID: $0.member.repositoryID, rank: $0.rank, changedAt: $0.changedAt)) })
            }
            return
        }
        // Older hosts order their own projects.
        if let source = project.members.first, let destination = merged.project(id: target)?.members.first(where: { $0.owner?.deviceID == source.owner?.deviceID }),
           let host = feed.host(for: source) {
            performOrderMutations([(host, .moveProject(id: source.id, relativeTo: destination.id, after: after))])
        }
    }

    private func movePinned(source: String, target: String, after: Bool, projectID: String) {
        let merged = merged
        guard let move = merged.pinnedMove(source: source, target: target, after: after, projectID: projectID, isWritable: { row in
            row.row.sidebar?.pinnedRank != nil && (row.availability == .reachable || row.id == source)
        }) else { return }
        switch move {
        case let .legacy(from, to, after):
            guard let host = feed.host(for: from.row), let repositoryID = from.row.repositoryID else { return }
            performOrderMutations([(host, .moveWorktree(repositoryID: repositoryID, worktreeID: from.row.path, relativeTo: to.row.path, after: after))])
        case let .ranks(writes):
            performOrderMutations(writes.compactMap { write in
                guard let host = feed.host(for: write.row.row), let repositoryID = write.row.row.repositoryID else { return nil }
                return (host, .setPinnedRank(repositoryID: repositoryID, worktreeID: write.row.row.path, rank: write.rank))
            })
        }
    }

    /// Each request goes to one host; a provider dial wakes a sleeping one.
    private func performOrderMutations(_ requests: [(Host, WorktreeManagementRequest)]) {
        guard !orderMutationInFlight, !requests.isEmpty else { return }
        let mutationID = UUID()
        orderMutationID = mutationID
        Task {
            defer { if orderMutationID == mutationID { orderMutationID = nil } }
            for (host, request) in requests {
                do {
                    let response = try await RelayedWorktreeManagementClient.send(request, using: feed.provider(for: host))
                    if case .error(_, let message, _, _) = response { showErrorToast(message) }
                } catch {
                    showErrorToast("Couldn't save the order on \(host.label). Reconnect and try again.")
                }
            }
        }
    }

    private func showReport(_ worktree: WorktreePanes) {
        guard reportWorktreeID == nil, case .loaded(let worktrees) = state else { return }
        selectionIntentGeneration &+= 1
        reportOrder = SidebarWorktreeReportOrder(worktrees: worktrees, projects: merged.projects.map(\.representative))
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
        if selectedWorktreePath != nil, let previous = worktrees.first(where: isSelected) {
            navigation.rememberedWorktrees[merged.mergedID(forMember: SidebarProjection.projectID(previous))] = MergedWorktreeList.identity(previous)
        }
        guard isSidebar, project.isAvailable else { return }
        let rows = merged.flattenedRows(for: project.id)
        // Choosing a project isn't reason enough to wake its hosts.
        if let target = rows.first(where: { $0.id == navigation.rememberedWorktrees[project.id] }) ?? rows.first,
           target.availability != .asleep {
            beginSelectingWorktree(target.row)
        }
    }

    static func applyProjectSelection(_ project: SidebarProject, navigation: SidebarNavigationState, selectionGeneration: inout UInt64) {
        // Invalidate before changing modes: offline and compact project picks
        // do not call beginSelectingWorktree, but must still cancel old opens.
        selectionGeneration &+= 1
        navigation.showProject(project.id)
    }

    private func openAttention(_ item: SidebarActivityItem, worktrees: [WorktreePanes]) async -> Bool {
        guard let worktree = worktrees.first(where: { $0.path == item.worktreeID }), worktree.state.hasOnDiskWorktree else {
            showErrorToast("This worktree is no longer available."); return false
        }
        guard feed.state.projects.first(where: { $0.id == item.projectID }).map({ feed.state.availability(of: $0) }) != .offline,
              let route = route(for: worktree) else {
            showErrorToast("The owning Mac is offline."); return false
        }
        selectionIntentGeneration &+= 1
        let generation = selectionIntentGeneration
        let host = route.host
        let provider: RemoteConnectionProvider? = route.provider
        do {
            var target = worktree
            if target.state == .closed {
                let response = try await RelayedWorktreeManagementClient.send(.open(worktreeID: target.path), using: provider)
                guard generation == selectionIntentGeneration else { return false }
                guard response == .ok else { showErrorToast("Couldn't open the worktree."); return false }
                func checkCurrent() throws {
                    guard generation == selectionIntentGeneration else { throw CancellationError() }
                }
                func fetch() async throws -> [WorktreePanes] {
                    let list = try await feed.fetchRows(on: host)
                    try checkCurrent()
                    return list
                }
                let path = target.path
                if let running = try await WorktreeLayoutAwait.poll(rows: try await fetch(), fetch: fetch, checkCurrent: checkCurrent,
                        ready: { rows in rows.first { $0.path == path && $0.layout != nil } }) {
                    target = running
                }
            }
            guard generation == selectionIntentGeneration, target.layout != nil else { return false }
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
            let supportsExactAcknowledgement = feed.state.projects
                .first(where: { $0.id == item.projectID })?.supportsWorktreeEditing == true
            guard generation == selectionIntentGeneration else { return false }
            if let leaf {
                onSelectPane(host, target, leaf)
            } else if let onSelectWorktreeDetail { onSelectWorktreeDetail(host, target) }
            else { onSelect(host, target) }
            // The visit has occurred. A delayed acknowledgement must not consume
            // an unopened request or later replace a newer navigation choice.
            if let request = SidebarInteractionPolicy.acknowledgementOnOpen(
                for: currentItem, supportsExactAcknowledgement: supportsExactAcknowledgement
            ) {
                Task {
                    do {
                        let response = try await RelayedWorktreeManagementClient.send(request, using: provider)
                        if case .error(let code, let message, _, _) = response, code != "occurrence-changed" { showErrorToast(message) }
                    } catch {
                        showErrorToast("Couldn't mark this request as viewed.")
                    }
                }
            }
            return true
        } catch {
            // A newer selection supersedes silently; a connection-layer
            // cancellation still reports the failure.
            guard generation == selectionIntentGeneration else { return false }
            showErrorToast("Couldn't open this request on the owning Mac.")
            return false
        }
    }

    @ViewBuilder
    private func worktreeList(_ worktrees: [WorktreePanes], merged: SidebarMergedRows, projectIDs: [String]) -> some View {
        let searching = !navigation.query.isEmpty
        let scrollKey = searching ? nil : SidebarLayoutPolicy.projectFilter(selectedID: selectedMergedID, showsProjectRail: showsProjectRail)
        ScrollViewReader { proxy in
                    List {
                        if searching {
                            ForEach(merged.projects) { project in
                                let rows = merged.flattenedRows(for: project.id).filter { navigation.worktreeContext($0.row).matches(query: navigation.query) }
                                if !rows.isEmpty {
                                    Section {
                                        ForEach(rows) { row in worktreeRow(row, merged: merged, worktrees: worktrees) }
                                    } header: {
                                        Text(project.name).foregroundColor(theme?.sidebarPrimaryText(isActive: false))
                                    }
                                }
                            }
                        } else {
                            ForEach(projectIDs, id: \.self) { projectID in
                                let sections = merged.sections(for: projectID)
                                Section {
                                    if !sections.pinned.isEmpty {
                                        SidebarWorktreeSectionHeader("Pinned Agents", isCollapsed: pinnedCollapsed(projectID), separatesPrecedingRows: false)
                                            .listRowInsets(SidebarWorktreeListStyle.projectRowInsets)
                                        if !pinnedCollapsed(projectID).wrappedValue {
                                            pinnedNodes(sections.pinned, projectID: projectID, merged: merged, worktrees: worktrees)
                                        }
                                    }
                                    if !sections.pinned.isEmpty, !sections.temporary.isEmpty {
                                        Divider().listRowSeparator(.hidden).listRowBackground(Color.clear)
                                    }
                                    ForEach(sections.temporary) { row in
                                        worktreeRow(row, merged: merged, worktrees: worktrees).moveDisabled(true)
                                    }
                                    ForEach(merged.offlineHosts(for: projectID), id: \.self) { host in
                                        Text("\(host) is offline").font(.caption).italic().foregroundStyle(.secondary)
                                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                                    }
                                } header: {
                                    if !showsProjectRail && project == nil {
                                        Text(merged.project(id: projectID)?.name ?? "").foregroundColor(theme?.sidebarPrimaryText(isActive: false))
                                    }
                                }
                            }
                        }
                    }
                    // Use the flat project column on iPhone and iPad.
                    .modifier(SidebarWorktreeListStyle(projectColumn: true))
                    .scrollContentBackground(.hidden)
                    .refreshable { await feed.refresh() }
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

    static func requiresManagementOpen(
        _ worktree: WorktreePanes,
        includesRemoteWorktrees: Bool,
        providerAvailable: Bool
    ) -> Bool {
        worktree.state == .closed
            && includesRemoteWorktrees
            && providerAvailable
    }

    static func shouldApplySelectionIntent(
        capturedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        capturedGeneration == currentGeneration
    }

    private func recordViewedStop(_ worktree: WorktreePanes) {
        if let stop = SidebarProjection.activity([worktree]).first(where: { $0.agentStop != nil }) {
            navigation.opened(stop)
        }
    }

    private func pinnedCollapsed(_ projectID: String) -> Binding<Bool> {
        let key = "sidebar.pinned.collapsed.\(projectID)"
        return Binding(
            get: { collapsedPinned[key] ?? UserDefaults.standard.bool(forKey: key) },
            set: { collapsedPinned[key] = $0; UserDefaults.standard.set($0, forKey: key) })
    }

    /// Rows and folders at one level. Only sibling rows can be reordered.
    private func pinnedNodes(_ nodes: [MergedWorktreeNode], projectID: String, merged: SidebarMergedRows, worktrees: [WorktreePanes]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            switch node {
            case .row(let row):
                worktreeRow(row, merged: merged, worktrees: worktrees)
                    .moveDisabled(!listEditMode.isEditing || row.row.isMainCheckout || row.row.state.isInFlight || orderMutationInFlight)
            case .folder(let id, let name, let children):
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsedFolders.contains(projectID + id) },
                    set: { if $0 { collapsedFolders.remove(projectID + id) } else { collapsedFolders.insert(projectID + id) } }
                )) {
                    pinnedNodes(children, projectID: projectID, merged: merged, worktrees: worktrees)
                } label: { Label(name, systemImage: "folder").font(.callout) }
                .listRowInsets(SidebarWorktreeListStyle.projectRowInsets)
                .moveDisabled(true)
            }
        }.onMove { offsets, destination in
            guard let source = offsets.first, source != destination, source + 1 != destination else { return }
            let target = destination > source ? destination - 1 : destination
            guard nodes.indices.contains(target), case .row(let moving) = nodes[source], case .row(let relativeTo) = nodes[target] else { return }
            movePinned(source: moving.id, target: relativeTo.id, after: destination > source, projectID: projectID)
        })
    }

    @ViewBuilder
    private func worktreeRow(_ row: MergedWorktreeRow, merged: SidebarMergedRows, worktrees: [WorktreePanes]) -> some View {
        let wt = row.row
        let memberID = SidebarProjection.projectID(wt)
        let member = feed.state.projects.first { $0.id == memberID }
        WorktreeBlock(
            worktree: wt,
            project: member,
            projectIconData: projectIcons[memberID],
            theme: theme,
            isActive: isSelected(wt),
            isOpening: openingWorktrees.contains(OpeningWorktreeKey(hostID: feed.state.hostID(for: wt), path: wt.path)),
            projectColumn: true,
            context: navigation.worktreeContext(wt),
            onSelect: { beginSelectingWorktree(wt) },
            isAsleep: row.availability == .asleep,
            hostText: SidebarMergedRows.hostText(row, isLocal: false),
            onReport: { showReport(wt) },
            onRemove: { pendingDelete = PendingDelete(worktree: wt, action: .delete) }
        )
        .popover(isPresented: Binding(
            get: { reportWorktreeID == wt.path },
            set: { if !$0, reportWorktreeID == wt.path { closeReport() } }
        ), arrowEdge: .leading) {
            MobileWorktreeReportContent(context: navigation.worktreeContext(wt), onOpen: {
                await openReportTarget(MobilePaneAttention.openTarget(for: navigation.worktreeContext(wt)), worktrees: feed.state.rows)
            }, onDismiss: {
                navigation.dismissRequest(in: navigation.worktreeContext(wt))
                closeReport()
            },
            onClose: { if reportWorktreeID == wt.path { closeReport() } },
            host: feed.host(for: wt), remoteConnectionProvider: feed.host(for: wt).map { feed.provider(for: $0) })
            .presentationCompactAdaptation(.sheet)
        }
        .id(wt.sidebar?.id ?? wt.path)
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

    /// Tapping a sleeping host's row is an interaction that needs it, so it
    /// wakes, and the worktree opens once the host has reported.
    private func wakeAndOpen(_ worktree: WorktreePanes, on host: Host) {
        let key = OpeningWorktreeKey(hostID: host.id, path: worktree.path)
        guard !openingWorktrees.contains(key) else { return }
        openingWorktrees.insert(key)
        wakeFailure = nil
        Task { @MainActor in
            defer { openingWorktrees.remove(key) }
            guard await feed.wake(host) else {
                wakeFailure = WakeFailure(worktree: worktree, host: host)
                return
            }
            let identity = MergedWorktreeList.identity(worktree)
            if let live = feed.state.rows.first(where: { MergedWorktreeList.identity($0) == identity }) {
                beginSelectingWorktree(live)
            } else {
                showErrorToast("This worktree is no longer available on \(host.label).")
            }
        }
    }

    private func beginSelectingWorktree(_ worktree: WorktreePanes) {
        guard let route = route(for: worktree) else {
            showErrorToast("The host for this worktree isn't connected.")
            return
        }
        if feed.state.isAsleep(route.host.id), !feed.state.isLive(route.host.id) {
            wakeAndOpen(worktree, on: route.host)
            return
        }
        rememberWorktree(worktree)
        selectionIntentGeneration &+= 1
        let generation = selectionIntentGeneration
        let selectionHost = route.host
        let provider: RemoteConnectionProvider? = route.provider
        if worktree.showsCreationProgress {
            onSelect(selectionHost, worktree)
            return
        }
        Task {
            await selectWorktree(
                worktree,
                generation: generation,
                selectionHost: selectionHost,
                provider: provider
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
        provider: RemoteConnectionProvider?
    ) async {
        func selectionIsCurrent() -> Bool {
            Self.shouldApplySelectionIntent(
                    capturedGeneration: generation,
                    currentGeneration: selectionIntentGeneration
                )
        }
        guard Self.requiresManagementOpen(
            worktree,
            includesRemoteWorktrees: true,
            providerAvailable: provider != nil
        ) else {
            if selectionIsCurrent() {
                onSelect(selectionHost, worktree)
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
                let list = try await feed.fetchRows(on: selectionHost)
                try checkCurrent()
                return list
            }
            if let opened = try await WorktreeLayoutAwait.poll(rows: try await fetch(), fetch: fetch, checkCurrent: checkCurrent,
                    ready: { rows in rows.first { $0.path == worktree.path && $0.state == .running && $0.layout != nil } }) {
                onSelect(selectionHost, opened)
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
        let provider: RemoteConnectionProvider? = submission.route.provider
        let request = submission.request
        let repository = submission.repository
        let rows = feed.state.rows
        let targetProject = feed.state.projects.first {
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
        navigation.selectedProjectID = merged.mergedID(forMember: targetProject?.id ?? SidebarProjection.projectID(placeholder))
        navigation.query = ""
        isAddSheetPresented = false
        Task {
            do {
                let worktreePath: String
                let result = try await RelayedWorktreeManagementClient.send(
                    .create(repositoryID: request.repoPath,
                            worktreeName: request.worktreeName,
                            branchName: request.branchName,
                            existingSource: submission.existingSource,
                            launchDefaultAgent: true,
                            agent: request.agent),
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
                worktreeCreation.complete(id, worktreePath: worktreePath)
                // A pushed frame may already have delivered the ready layout
                // while the management response was still in flight.
                rowsChanged()
                await feed.refresh()
            } catch {
                worktreeCreation.fail(id)
                let message = (error as? CreateWorktreeClient.CreateError)?.userMessage
                    ?? CreateWorktreeClient.CreateError.transport.userMessage
                showErrorToast("Could not create worktree: " + message)
                await feed.refresh()
            }
        }
    }

    /// Issue the delete request; on success refresh in place, on
    /// forceable failure surface the Force Delete confirmation, on
    /// any other failure surface a transient error toast.
    private func performDelete(worktree: WorktreePanes, force: Bool) async {
        guard let route = route(for: worktree) else {
            showErrorToast("The host for this worktree isn't connected.")
            return
        }
        await sendDelete(
            worktreePath: worktree.path,
            force: force,
            requestContext: DeleteRequestContext(host: route.host, remoteConnectionProvider: route.provider)
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
            await feed.refresh()
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

#endif
