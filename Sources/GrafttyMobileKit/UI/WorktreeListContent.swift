#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import OSLog
import SwiftUI

private let projectIconLogger = Logger(subsystem: "com.quotably.graftty", category: "project-icon")

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
    /// The system's default row padding makes a single line about 74 points tall.
    private static let projectsCardRowInsets = EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
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
    /// The project New worktree was tapped in, so the sheet starts there.
    @State private var newWorktreeProjectID: String?
    /// Shared with the screens pushed above the list, so their headers draw
    /// the same images; a local cache stands in when none is provided.
    @Environment(\.projectIconCache) private var sharedProjectIconCache
    @Environment(\.worktreeDrawingCache) private var sharedWorktreeDrawingCache
    @State private var localProjectIconCache = ProjectIconCache()
    @State private var localWorktreeDrawingCache = WorktreeDrawingCache()
    private var projectIconCache: ProjectIconCache { sharedProjectIconCache ?? localProjectIconCache }
    private var worktreeDrawingCache: WorktreeDrawingCache { sharedWorktreeDrawingCache ?? localWorktreeDrawingCache }
    private var projectIcons: [String: Data] { projectIconCache.icons }
    @State private var listEditMode: EditMode = .inactive
    /// A row's merged identity: paths alone can repeat across hosts.
    @State private var reportWorktreeID: String?
    /// Holds rows still while someone is reaching for one, so a row doesn't
    /// move out from under a finger or a report when activity arrives.
    @State private var rowHold: WorktreeActivitySections.Hold?
    @State private var isTouchingList = false
    @State private var showsAllProjectsNeedingYou = false
    @State private var orderMutationID: UUID?
    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    @State private var worktreeScrollSpace = UUID()
    @State private var restoringWorktreeScroll = false
    @State private var restoredWorktreeProjectID: String?
    private var orderMutationInFlight: Bool { orderMutationID != nil }
    /// The iPad sidebar paints a themed background that system colors don't follow.
    var sectionTitleColor: Color { theme?.sidebarSecondaryText ?? .secondary }
    private var isHoldingRows: Bool { isTouchingList || reportWorktreeID != nil || listEditMode.isEditing }
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
    public let onSelect: (Host, WorktreePanes) -> Void
    public let onSelectPane: (Host, WorktreePanes, PaneLayoutNode.Leaf) -> Void
    private let onSelectWorktreeDetail: ((Host, WorktreePanes) -> Void)?

    public init(
        feed: MultiHostFeed,
        isSidebar: Bool = false,
        theme: GhosttyThemeColors? = nil,
        selectedHostID: UUID? = nil,
        selectedWorktreePath: String? = nil,
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
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
        self.onSelectWorktreeDetail = onSelectWorktreeDetail
        self.navigation = navigation ?? SidebarNavigationState(prefix: "sidebar.mobile", collapsed: true)
        self.navigationWindowWidth = navigationWindowWidth
    }

    /// Includes rows for worktrees still being created (IOS-9.5).
    private var merged: SidebarMergedRows {
        feed.state.merged(localDeviceID: nil, rows: worktreeCreation.isEmpty ? nil : worktreeCreation.rows(in: feed.state.rows))
    }

    /// A compact destination can name one host's project, from a context link
    /// or a restored selection. Rows are grouped under the merged project.
    private func destinationProjectID(in merged: SidebarMergedRows) -> String? {
        project.map { merged.selectedProjectID(for: $0.id) ?? $0.id }
    }

    /// Pass a `merged` already built for this render: building it groups every row.
    private func selectedMergedID(in merged: SidebarMergedRows) -> String? {
        merged.selectedProjectID(for: navigation.selectedProjectID)
    }

    private var selectedMergedID: String? { selectedMergedID(in: merged) }

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

    /// Hides the request here at once, then has the owning Mac retire it so
    /// every client stops showing it (LAYOUT-2.218).
    private func dismissRequest(_ worktree: WorktreePanes) {
        let context = navigation.worktreeContext(worktree)
        navigation.dismissRequest(in: context)
        let supportsExact = feed.state.projects
            .first { $0.id == SidebarProjection.projectID(worktree) }?.supportsWorktreeEditing == true
        let requests = SidebarAttentionDismissal.requests(for: context, supportsExactAcknowledgement: supportsExact)
        guard !requests.isEmpty, let provider = route(for: worktree)?.provider else { return }
        Task {
            do {
                if let message = try await SidebarAttentionDismissal.retire(requests, send: {
                    try await RelayedWorktreeManagementClient.send($0, using: provider)
                }) { showErrorToast(message) }
            } catch {
                showErrorToast("Couldn't dismiss this request on the owning Mac.")
            }
        }
    }

    private func isSelected(_ worktree: WorktreePanes) -> Bool {
        worktree.path == selectedWorktreePath && feed.state.hostID(for: worktree) == selectedHostID
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
        .onChange(of: isHoldingRows) { _, holding in rowHold = holding ? activitySections(merged, holding: nil).hold : nil }
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
                    Button("Retry") { Task { await feed.retry() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded:
                navigationContent()
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
        // and the iPad sidebar shows none.
        .toolbar {
            // A project's own list has New worktree under its tiles (LAYOUT-2.227).
            if !isSidebar && destinationProjectID(in: merged) == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        newWorktreeProjectID = nil
                        isAddSheetPresented = true
                    } label: {
                        Label("Add Worktree", systemImage: "plus")
                    }
                    .accessibilityLabel("Add Worktree")
                }
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddWorktreeSheetView(targets: addWorktreeTargets,
                                 initialProjectID: newWorktreeProjectID ?? destinationProjectID(in: merged) ?? (isSidebar ? selectedMergedID : nil)) { submission in
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
        let selected = selectedMergedID(in: merged)
        if selected == nil {
            navigation.selectedProjectID = rows.first(where: isSelected).map { merged.mergedID(forMember: SidebarProjection.projectID($0)) }
                ?? merged.projects.first?.id
        } else if navigation.selectedProjectID != selected {
            navigation.selectedProjectID = selected
        }
        let members = merged.projects.compactMap(\.iconMember)
        projectIconCache.reconcile(members)
        // Each image comes from the host that reported it, and only a host
        // that's answering now: a fetch must not wake a sleeping one.
        let feed = feed
        Self.loadProjectIcons(members.filter { merged.availability(ofMember: $0.id) == .reachable },
                              into: projectIconCache) { member, revision in
            guard let host = feed.host(for: member) else { return nil }
            return await Self.fetchIcon(.projectIcon(repositoryID: member.repositoryID, revision: revision),
                                        using: feed.provider(for: host, wake: .never))
        }
        Self.loadDrawings(rows.filter { feed.state.hostID(for: $0).map(feed.state.isLive) == true },
                          into: worktreeDrawingCache) { worktree, revision in
            guard let host = feed.host(for: worktree) else { return nil }
            return await Self.fetchIcon(.worktreeIcon(worktreeID: worktree.path, revision: revision),
                                        using: feed.provider(for: host, wake: .never))
        }
    }

    /// Image fetches run outside the list's tasks: the screens pushed above it
    /// draw from the same caches, and a push cancels this view's tasks (IOS-4.64).
    static func loadProjectIcons(_ projects: [SidebarProject], into cache: ProjectIconCache,
                                 fetch: @escaping @MainActor (SidebarProject, String) async -> Data?) {
        Task {
            for project in projects where project.isAvailable {
                guard let revision = project.iconRevision else { continue }
                await cache.load(for: project) { await fetch(project, revision) }
            }
        }
    }

    /// Like project icons, drawings load outside the list's tasks (IOS-4.65).
    static func loadDrawings(_ worktrees: [WorktreePanes], into cache: WorktreeDrawingCache,
                             fetch: @escaping @MainActor (WorktreePanes, String) async -> Data?) {
        let pending = worktrees.compactMap { worktree -> (WorktreePanes, String)? in
            guard case .drawing(let revision, _) = worktree.iconIdentity, cache.images[revision] == nil else { return nil }
            return (worktree, revision)
        }
        guard !pending.isEmpty else { return }
        Task {
            for (worktree, revision) in pending {
                await cache.load(revision: revision) { await fetch(worktree, revision) }
            }
        }
    }

    private static func fetchIcon(_ request: WorktreeManagementRequest, using provider: RemoteConnectionProvider?) async -> Data? {
        do {
            let response = try await RelayedWorktreeManagementClient.send(request, using: provider)
            if case .icon(let data) = response { return data }
            projectIconLogger.error("icon refused: \(String(describing: response), privacy: .public)")
        } catch {
            projectIconLogger.error("icon fetch failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    private func rowsChanged() {
        let list = feed.state.rows
        if let reportWorktreeID, !list.contains(where: { MergedWorktreeList.identity($0) == reportWorktreeID }) { closeReport() }
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
        let merged = merged
        guard isSidebar || !showsProjectRail || destinationProjectID(in: merged) == selectedMergedID(in: merged),
              let item = MobilePaneAttention.pendingRoute(for: navigation),
              case .loaded(let rows) = state,
              rows.contains(where: { $0.path == item.worktreeID && SidebarProjection.projectID($0) == item.projectID }) else { return }
        MobilePaneAttention.consumePendingRoute(for: navigation)
        // Consuming the route changes the task identity. Keep opening outside
        // that task so its cancellation cannot interrupt navigation.
        Task { await openReportTarget(item, worktrees: rows) }
    }

    @ViewBuilder
    private func navigationContent() -> some View {
        let merged = merged
        // A sleeping host's last report says nothing about what's happening now.
        let live = feed.state.liveRows
        let projects = merged.projects.map(\.representative)
        let activityCounts = SidebarActivityCounts(items: SidebarProjection.activity(live))
        let working = merged.rekeyed(activityCounts.workingByProject)
        let counts = merged.rekeyed(SidebarWaitingCounts.byProject(live) { navigation.worktreeContext($0) })
        let icons = mergedIcons(merged)
        if !isSidebar, let projectID = destinationProjectID(in: merged) {
            projectDetail(merged: merged, projectID: projectID)
        } else if !showsProjectRail {
            worktreeList(merged: merged, projectIDs: merged.projects.map(\.id))
        } else if isSidebar {
            HStack(spacing: 0) {
                ProjectNavigationRail(projects: projects, counts: counts, workingCounts: working, icons: icons,
                                      selectedID: selectedMergedID(in: merged),
                                      collapsed: Binding(get: {
                    SidebarLayoutPolicy.railCollapsed(preference: navigation.railCollapsed, isMobile: true, windowWidth: navigationWindowWidth)
                }, set: { navigation.railCollapsed = $0 }),
                                      expandedWidth: $navigation.railExpandedWidth,
                                      allowsReordering: !orderMutationInFlight,
                                      canExpand: navigationWindowWidth >= 1100,
                                      selectionColor: theme?.foreground.opacity(0.16) ?? .primary.opacity(0.12),
                                      onSelect: { project in selectProject(project) },
                                      onMove: moveProject)
                Divider()
                projectDetail(merged: merged)
                    .frame(minWidth: 220, maxWidth: .infinity)
            }
        } else {
            List {
                pendingCreationRows()
                let needingYou = activitySections(merged, holding: rowHold).needsYou
                if !needingYou.isEmpty {
                    let preview = WorktreeActivitySections.preview(needingYou, showsAll: showsAllProjectsNeedingYou)
                    Section {
                        ForEach(preview.rows) { row in worktreeRow(row, merged: merged, namesProject: true) }
                        if preview.hidden > 0 {
                            Button("\(preview.hidden) more") { showsAllProjectsNeedingYou = true }
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .listRowInsets(Self.projectsCardRowInsets)
                        }
                    } header: {
                        // A header, not a row: this list's rows sit in a card that
                        // only rounds the corners of its first and last rows.
                        WorktreeListSectionTitle("Needs you", count: needingYou.count, tone: .attention).padding(.bottom, 4)
                    }
                }
                Section {
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
                        .listRowInsets(Self.projectsCardRowInsets)
                    }.onMove { offsets, destination in
                        guard let source = offsets.first, source != destination, source + 1 != destination else { return }
                        let target = destination > source ? destination - 1 : destination
                        guard projects.indices.contains(target) else { return }
                        moveProject(projects[source].id, projects[target].id, destination > source)
                    }.moveDisabled(orderMutationInFlight)
                } header: {
                    if !needingYou.isEmpty { WorktreeListSectionTitle("All projects", tone: .standard(sectionTitleColor)).padding(.bottom, 4) }
                }
            }
            .background(ListTouchTracker(isTouching: $isTouchingList))
            .toolbar { listOptions }
            // This screen has no search of its own. A query left behind would
            // filter the next list opened, with that list's search field hidden.
            .onAppear { if !navigation.query.isEmpty { navigation.query = "" } }
        }
    }

    private func sectionTitle(_ title: String, count: Int? = nil, tone: WorktreeListSectionTitle.Tone,
                              isCollapsed: Binding<Bool>? = nil) -> some View {
        WorktreeListSectionTitle(title, count: count, tone: tone, isCollapsed: isCollapsed)
            .listRowInsets(SidebarWorktreeListStyle.projectRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
    }

    /// Reordering is occasional, so it stays out of the way until asked for.
    /// While it's on, its way out has to be visible.
    @ToolbarContentBuilder
    private var listOptions: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if listEditMode.isEditing {
                Button("Done") { withAnimation { listEditMode = .inactive } }
            } else {
                Menu {
                    Button("Edit", systemImage: "pencil") { withAnimation { listEditMode = .active } }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    /// Row identity is unique across projects, so one set of sections covers a
    /// project screen, the Projects screen, and a hold shared between them.
    /// The Projects screen has no tiles, so waiting pinned agents join its Needs you;
    /// a project's own list keeps them on their tiles.
    private func activitySections(_ merged: SidebarMergedRows, projectIDs: [String]? = nil,
                                  holding hold: WorktreeActivitySections.Hold?) -> WorktreeActivitySections {
        let parts = (projectIDs ?? merged.projects.map(\.id)).map { merged.sections(for: $0) }
        return WorktreeActivitySections.make(pinned: parts.flatMap(\.pinned), temporary: parts.flatMap(\.temporary),
                                             context: { navigation.worktreeContext($0) }, holding: hold,
                                             pullsWaitingPins: projectIDs == nil)
    }

    private func mergedIcons(_ merged: SidebarMergedRows) -> [String: Data] {
        var result: [String: Data] = [:]
        for project in merged.projects {
            if let member = project.iconMember { result[project.id] = projectIcons[member.id] }
        }
        return result
    }

    private func projectDetail(merged: SidebarMergedRows, projectID: String? = nil) -> some View {
        let selectedProjectID = projectID ?? selectedMergedID(in: merged)
        return VStack(spacing: 0) {
            if !isSidebar {
                pendingCreationRows(excludingProjectID: selectedProjectID)
                    .padding(.horizontal, 10)
            }
            if let selected = merged.project(id: selectedProjectID), !selected.representative.isAvailable {
                Text("Every host for this project is offline.").font(.caption).foregroundStyle(.secondary)
            }
            worktreeList(merged: merged, projectIDs: selectedProjectID.map { [$0] } ?? [])
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
                    SidebarWorktreeRowLayout {
                        WorktreeBlockIdentity(worktree: worktree, project: nil, projectIconData: nil,
                                              theme: theme, status: .none, isOpening: false)
                    } content: {
                        WorktreeRowContent(worktree: worktree, theme: theme, isActive: false, isOpening: false)
                    }
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
        // Every host for this project needs reconnection. A rank needs somewhere to be
        // stored, so wake one; it only moves once that host has it.
        if project.availability == .wakeable, let member = project.members.first(where: { $0.rank != nil }), let host = feed.host(for: member) {
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
        guard reportWorktreeID == nil, case .loaded = state else { return }
        selectionIntentGeneration &+= 1
        reportWorktreeID = MergedWorktreeList.identity(worktree)
    }

    private func closeReport() {
        guard reportWorktreeID != nil else { return }
        selectionIntentGeneration &+= 1
        reportWorktreeID = nil
    }

    private func openReportTarget(_ item: SidebarActivityItem, worktrees: [WorktreePanes]) async -> Bool {
        let token = navigation.beginOpening(item)
        let succeeded = await openAttention(item, worktrees: worktrees)
        navigation.finishOpening(token, succeeded: succeeded, navigateToProject: true)
        return succeeded
    }

    private func selectProject(_ project: SidebarProject) {
        Self.applyProjectSelection(project, navigation: navigation, selectionGeneration: &selectionIntentGeneration)
        if selectedWorktreePath != nil, let previous = feed.state.rows.first(where: isSelected) {
            navigation.rememberedWorktrees[merged.mergedID(forMember: SidebarProjection.projectID(previous))] = MergedWorktreeList.identity(previous)
        }
        guard isSidebar, project.isAvailable else { return }
        let rows = merged.flattenedRows(for: project.id)
        // Choosing a project isn't reason enough to wake its hosts.
        if let target = rows.first(where: { $0.id == navigation.rememberedWorktrees[project.id] }) ?? rows.first,
           target.availability != .wakeable {
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
        // The project tells apart worktrees at the same path on different hosts.
        guard let listed = worktrees.first(where: { $0.path == item.worktreeID && SidebarProjection.projectID($0) == item.projectID }),
              listed.state.hasOnDiskWorktree else {
            showErrorToast("This worktree is no longer available."); return false
        }
        guard let route = route(for: listed) else {
            showErrorToast("The owning Mac is offline."); return false
        }
        let routeIntent = feed.beginRouteSelection()
        defer { feed.endRouteSelection(routeIntent) }
        selectionIntentGeneration &+= 1
        let generation = selectionIntentGeneration
        do {
            let resolved = try await feed.resolveWorktreeRoute(listed, from: route.host)
            guard generation == selectionIntentGeneration else { return false }
            let host = resolved.host
            let provider: RemoteConnectionProvider? = feed.provider(for: host)
            var target = resolved.worktree
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
    private func worktreeList(merged: SidebarMergedRows, projectIDs: [String]) -> some View {
        let searching = !navigation.query.isEmpty
        let scrollKey = searching ? nil : SidebarLayoutPolicy.projectFilter(selectedID: selectedMergedID(in: merged), showsProjectRail: showsProjectRail)
        ScrollViewReader { proxy in
                    List {
                        if searching {
                            ForEach(merged.projects) { project in
                                let rows = merged.flattenedRows(for: project.id).filter { navigation.worktreeContext($0.row).matches(query: navigation.query) }
                                if !rows.isEmpty {
                                    Section {
                                        ForEach(rows) { row in worktreeRow(row, merged: merged) }
                                    } header: {
                                        Text(project.name).foregroundColor(theme?.sidebarPrimaryText(isActive: false))
                                    }
                                }
                            }
                        } else {
                            ForEach(projectIDs, id: \.self) { projectID in
                                let sections = activitySections(merged, projectIDs: [projectID], holding: rowHold)
                                Section {
                                    if !sections.pinned.isEmpty {
                                        pinnedTiles(sections.pinned, projectID: projectID, merged: merged)
                                    }
                                    if merged.project(id: projectID)?.representative.isAvailable == true {
                                        newWorktreeRow(projectID: projectID)
                                    }
                                    if !sections.needsYou.isEmpty {
                                        sectionTitle("Needs you", count: sections.needsYou.count, tone: .attention)
                                        ForEach(sections.needsYou) { row in worktreeRow(row, merged: merged).moveDisabled(true) }
                                    }
                                    if !sections.working.isEmpty {
                                        sectionTitle("Working", count: sections.working.count, tone: .standard(sectionTitleColor))
                                        ForEach(sections.working) { row in worktreeRow(row, merged: merged).moveDisabled(true) }
                                    }
                                    if !sections.recent.isEmpty {
                                        sectionTitle("Recent", tone: .standard(sectionTitleColor))
                                        ForEach(sections.recent) { row in worktreeRow(row, merged: merged).moveDisabled(true) }
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
                    .searchable(text: $navigation.query, placement: .navigationBarDrawer(displayMode: .automatic),
                                prompt: "Find any project or worktree")
                    .toolbar { listOptions }
                    .background(ListTouchTracker(isTouching: $isTouchingList))
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

    /// Pinned agents as tiles that light up in place (LAYOUT-2.225): tap opens,
    /// a long press offers the row's menu, and dragging one onto another reorders.
    private func pinnedTiles(_ rows: [MergedWorktreeRow], projectID: String, merged: SidebarMergedRows) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: PinnedTile.minimumWidth), spacing: 8)], spacing: 8) {
            ForEach(rows) { row in
                pinnedTile(row, merged: merged)
                    .draggable(row.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let source = ids.first, source != row.id, !orderMutationInFlight,
                              let from = rows.firstIndex(where: { $0.id == source }),
                              let to = rows.firstIndex(where: { $0.id == row.id }) else { return false }
                        movePinned(source: source, target: row.id, after: from < to, projectID: projectID)
                        return true
                    }
            }
        }
        .padding(.vertical, 6)
        .listRowInsets(SidebarWorktreeListStyle.projectRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
    }

    private func pinnedTile(_ row: MergedWorktreeRow, merged: SidebarMergedRows) -> some View {
        let wt = row.row
        let context = navigation.worktreeContext(wt)
        let isCached = row.availability == .wakeable
        let state = PinnedTileState.resolve(status: SidebarRowStatus.resolve(context: context, worktree: wt, isCached: isCached),
                                            isCached: isCached)
        let memberID = SidebarProjection.projectID(wt)
        let project = feed.state.projects.first { $0.id == memberID }
            ?? SidebarProject(id: memberID, repositoryID: wt.repositoryID ?? memberID, name: wt.repoDisplayName)
        let host = row.showsHostLabel ? row.hostLabel : nil
        return PinnedTileFace(identity: wt.iconIdentity, project: project,
                              imageData: MobileWorktreeIdentity.iconData(for: wt, in: projectIcons, drawings: worktreeDrawingCache.images),
                              word: PinnedTile.word(name: row.leafName, isMainCheckout: wt.isMainCheckout, branch: wt.displayBranch),
                              hostBadge: host, state: state, isSelected: isSelected(wt),
                              fill: theme?.foreground.opacity(0.07) ?? Color.primary.opacity(0.06),
                              selectedFill: theme?.foreground.opacity(0.16) ?? Color.primary.opacity(0.12))
            .onTapGesture { beginSelectingWorktree(wt) }
            .contextMenu {
                if !wt.state.isInFlight {
                    MobileWorktreeRowMenu(context: context, onReport: { showReport(wt) }, onDismiss: { dismissRequest(wt) })
                }
            }
            .modifier(reportPopover(wt))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PinnedTile.accessibilityLabel(name: row.leafName, host: host, state: state))
            .accessibilityAddTraits(isSelected(wt) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { beginSelectingWorktree(wt) }
            .id(wt.sidebar?.id ?? wt.path)
    }

    /// LAYOUT-2.227: where a new worktree starts, directly under the tiles.
    private func newWorktreeRow(projectID: String) -> some View {
        Button {
            newWorktreeProjectID = projectID
            isAddSheetPresented = true
        } label: {
            Label("New worktree", systemImage: "plus")
                .font(.subheadline)
                .foregroundStyle(sectionTitleColor)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New worktree in \(merged.project(id: projectID)?.name ?? "this project")")
        .listRowInsets(SidebarWorktreeListStyle.projectRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
    }

    private func reportPopover(_ wt: WorktreePanes) -> ReportPopover {
        let reportID = MergedWorktreeList.identity(wt)
        return ReportPopover(isPresented: Binding(
            get: { reportWorktreeID == reportID },
            set: { if !$0, reportWorktreeID == reportID { closeReport() } }
        )) {
            MobileWorktreeReportContent(context: navigation.worktreeContext(wt), onOpen: {
                await openReportTarget(MobilePaneAttention.openTarget(for: navigation.worktreeContext(wt)), worktrees: feed.state.rows)
            }, onDismiss: {
                dismissRequest(wt)
                closeReport()
            },
            onClose: { if reportWorktreeID == reportID { closeReport() } },
            host: feed.host(for: wt), remoteConnectionProvider: feed.host(for: wt).map { feed.provider(for: $0) })
        }
    }

    @ViewBuilder
    private func worktreeRow(_ row: MergedWorktreeRow, merged: SidebarMergedRows, namesProject: Bool = false) -> some View {
        let wt = row.row
        let memberID = SidebarProjection.projectID(wt)
        let member = feed.state.projects.first { $0.id == memberID }
        WorktreeBlock(
            worktree: wt,
            project: member,
            projectIconData: MobileWorktreeIdentity.iconData(for: wt, in: projectIcons, drawings: worktreeDrawingCache.images),
            theme: theme,
            isActive: isSelected(wt),
            isOpening: openingWorktrees.contains(OpeningWorktreeKey(hostID: feed.state.hostID(for: wt), path: wt.path)),
            projectColumn: true,
            context: navigation.worktreeContext(wt),
            onSelect: { beginSelectingWorktree(wt) },
            isCached: row.availability == .wakeable,
            hostText: namesProject ? nil : SidebarMergedRows.hostText(row, isLocal: false),
            eyebrow: namesProject
                ? [merged.project(id: merged.mergedID(forMember: memberID))?.name, SidebarMergedRows.hostText(row, isLocal: false)]
                    .compactMap { $0 }.joined(separator: " · ")
                : nil,
            onReport: { showReport(wt) },
            onRemove: { pendingDelete = PendingDelete(worktree: wt, action: .delete) },
            onDismissRequest: { dismissRequest(wt) }
        )
        .modifier(reportPopover(wt))
        .id(wt.sidebar?.id ?? wt.path)
        .background(GeometryReader { geometry in
            let frame = geometry.frame(in: .named(worktreeScrollSpace))
            Color.clear.preference(key: SidebarWorktreeViewportPreference.self, value: [
                SidebarWorktreeViewportRow(id: wt.sidebar?.id ?? wt.path, minY: frame.minY, maxY: frame.maxY,
                                           projectID: merged.mergedID(forMember: memberID))
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

    private func beginSelectingWorktree(_ worktree: WorktreePanes) {
        guard let route = route(for: worktree) else {
            showErrorToast("The host for this worktree isn't connected.")
            return
        }
        rememberWorktree(worktree)
        selectionIntentGeneration &+= 1
        let generation = selectionIntentGeneration
        let selectionHost = route.host
        if worktree.showsCreationProgress {
            onSelect(selectionHost, worktree)
            return
        }
        let routeIntent = feed.beginRouteSelection()
        let routeOpeningKey = OpeningWorktreeKey(hostID: selectionHost.id, path: worktree.path)
        openingWorktrees.insert(routeOpeningKey)
        Task {
            defer { feed.endRouteSelection(routeIntent); openingWorktrees.remove(routeOpeningKey) }
            do {
                let resolved = try await feed.resolveWorktreeRoute(worktree, from: selectionHost)
                guard generation == selectionIntentGeneration else { return }
                openingWorktrees.remove(routeOpeningKey)
                await selectWorktree(resolved.worktree, generation: generation,
                    selectionHost: resolved.host, provider: feed.provider(for: resolved.host))
            } catch is CancellationError { return }
            catch {
                guard generation == selectionIntentGeneration else { return }
                showErrorToast(error.localizedDescription)
            }
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
            placeholder: placeholder,
            // A path on another host says nothing about this one.
            knownPaths: Set(rows.filter { repository.origin == nil || $0.origin?.deviceID == repository.origin?.deviceID }.map(\.path)),
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

/// A row's or tile's report, a popover that becomes a sheet on iPhone.
private struct ReportPopover: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> MobileWorktreeReportContent

    func body(content view: Content) -> some View {
        view.popover(isPresented: $isPresented, arrowEdge: .leading) {
            content().presentationCompactAdaptation(.sheet)
        }
    }
}
#endif
