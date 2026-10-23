#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

public struct RootView: View {

    @State private var hostStore = HostStore()
    @State private var gate = BiometricGate()
    @State private var navigationPath = NavigationPath()
    @State private var notifications = MobileAgentNotifications.shared
    @State private var notificationError: String?
    @State private var activatingNotificationRoute: MobileStopNotificationRoute?
    @State private var activatingNotificationIntent: UInt64?
    @State private var navigationIntent = MobileNavigationIntent()
    @State private var recentPaneOpeningID: UUID?
    @State private var recentPaneError: String?
    @State private var contextWorktreeError: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var iPadAppState = IPadAppState()
    @State private var retainedPanes = RetainedPaneClientPool<RetainedMobilePane>()
    @State private var notificationPaneActivation = MobileNotificationPaneActivation()
    @State private var notificationActivationPath: NavigationPath?
    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    /// Owned here (not per-screen) so a negotiated SSH connection survives
    /// navigation-stack pushes/pops on the compact path and layout
    /// transitions on the iPad path. `body` injects this one instance as
    /// `\.remoteConnectionCoordinator` for both size classes, so a host
    /// negotiated once from either surface is cached for the other.
    @State private var coordinator = RemoteConnectionCoordinator(
        connectionsAllowedInitially: false
    )
    @State private var nearbyMacBrowser = NearbyMacBrowser()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    struct NotificationIO {
        let fetch: @MainActor (Host) async throws -> [WorktreePanes]
        let reopen: @MainActor (Host, String) async throws -> Void
    }
    private var notificationIO: NotificationIO?
    private var notificationConnectionProvider: RemoteConnectionProvider?

    public init() {}

    // The isolated native interaction host supplies controlled remote I/O while
    // retaining this view's real lifecycle, notification delegate and navigation.
    init(hostStore: HostStore, gate: BiometricGate, notifications: MobileAgentNotifications,
        appState: IPadAppState, notificationIO: NotificationIO,
        connectionProvider: RemoteConnectionProvider? = nil,
        retainedPanes: RetainedPaneClientPool<RetainedMobilePane>? = nil) {
        _hostStore = State(initialValue: hostStore)
        _gate = State(initialValue: gate)
        _notifications = State(initialValue: notifications)
        _iPadAppState = State(initialValue: appState)
        self.notificationIO = notificationIO
        self.notificationConnectionProvider = connectionProvider
        if let retainedPanes { _retainedPanes = State(initialValue: retainedPanes) }
    }

    public var body: some View {
        ZStack {
            switch horizontalSizeClass {
            case .regular:
                IPadRootLayout(
                    hostStore: hostStore,
                    appState: iPadAppState,
                    nearbyMacBrowser: nearbyMacBrowser
                )
            default:
                compactBody
            }
            if gate.state == .locked {
                lockOverlay
            }
        }
        .environment(\.biometricGate, gate)
        .environment(\.remoteConnectionCoordinator, coordinator)
        .environment(\.remoteWorktreeUpdates, RemoteWorktreeUpdatesProvider { [coordinator] host in
            coordinator.isPaired(host) ? coordinator.worktreeUpdates(for: host) : nil
        })
        .environment(\.worktreeContextActions, WorktreeContextActions { [hostID = iPadAppState.selectedHostId] path, source in
            openContextWorktree(path, source: source, hostID: hostID)
        })
        .alert("Could not open worktree", isPresented: Binding(
            get: { contextWorktreeError != nil }, set: { if !$0 { contextWorktreeError = nil } }
        )) { Button("OK") { contextWorktreeError = nil } } message: { Text(contextWorktreeError ?? "") }
        .environment(\.mobileNotificationPaneActivation, notificationPaneActivation)
        .environment(\.recentPaneActions, MobileRecentPaneActions(history: iPadAppState.recentPanes, open: { entry in
            let id = UUID()
            navigationIntent.begin()
            notificationPaneActivation.cancel()
            if let pending = notifications.pendingRoute { notifications.consume(pending) }
            recentPaneOpeningID = id
            Task { await openRecentPane(entry, openingID: id) }
        }))
        .onChange(of: navigationPath) { _, path in
            recentPaneOpeningID = nil
            // System Back can pop the stack without changing sidebar selection.
            if let expected = notificationActivationPath, path != expected {
                notificationPaneActivation.cancel()
                notificationActivationPath = nil
            }
        }
        .onChange(of: notificationSelection) { _, _ in
            recentPaneOpeningID = nil
            notificationPaneActivation.discard(unlessHostID: iPadAppState.selectedHostId,
                                               sessionName: iPadAppState.focusedPaneId)
            recordSelectedPane()
        }
        .onChange(of: iPadAppState.latestWorktrees) { _, _ in recordSelectedPane() }
        .onChange(of: iPadAppState.selectedHostId) { _, _ in retainedPanes.stopAll() }
        .onChange(of: horizontalSizeClass) { previous, current in
            retainedPanes.stopAll()
            guard previous == .regular, current != .regular else { return }
            syncCompactNavigationToSelection()
        }
        .onChange(of: gate.state) { _, _ in
            updateConnectionAccess()
            Task {
                if gate.state == .unlocked { await notifications.requestAuthorization() }
                await activateNotification()
            }
        }
        .onChange(of: notifications.pendingRoute) { _, route in
            if route != nil {
                notificationPaneActivation.cancel()
                navigationIntent.begin()
                recentPaneOpeningID = nil
            }
            Task { await activateNotification() }
        }
        .task { await activateNotification() }
        .alert("Could not open notification", isPresented: Binding(
            get: { notificationError != nil }, set: { if !$0 { notificationError = nil } }
        )) { Button("OK") { notificationError = nil } } message: { Text(notificationError ?? "") }
        .alert("Could not open pane", isPresented: Binding(
            get: { recentPaneError != nil }, set: { if !$0 { recentPaneError = nil } }
        )) { Button("OK") { recentPaneError = nil } } message: { Text(recentPaneError ?? "") }
        .onAppear { if notificationIO == nil { nearbyMacBrowser.start() } }
        .onChange(of: nearbyMacBrowser.candidates) { _, candidates in
            coordinator.updateDiscoveryCandidates(candidates)
            for candidate in candidates
            where coordinator.isTrustedDiscoveryCandidate(candidate) {
                try? hostStore.refreshDiscoveredDevice(
                    id: candidate.deviceID,
                    label: candidate.label,
                    baseURL: candidate.baseURL
                )
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            switch newPhase {
            case .background:
                gate.applicationDidEnterBackground()
                // Only `.background`, not `.inactive`: IPAD-5.1 is scoped to
                // "enters the background." `.inactive` also fires for
                // Control Center pulls / app-switcher / call banners, where
                // tearing down every negotiated connection would force a
                // needless full re-negotiation on the very next frame —
                // Per-view terminal channels also survive `.inactive` per
                // IOS-10.1, avoiding churn while the shared transport is
                // intentionally kept alive.
                updateConnectionAccess()
            case .active:
                gate.applicationWillEnterForeground()
                updateConnectionAccess()
                Task {
                    await gate.authenticateOnActivation()
                    await activateNotification()
                }
            case .inactive:
                gate.applicationDidBecomeInactive()
            @unknown default:
                break
            }
        }
    }

    private func recordSelectedPane() {
        // Compact worktree selection can display pane previews. Its terminal
        // records the visit only after SingleSessionView actually opens.
        guard horizontalSizeClass == .regular,
              let host = hostStore.hosts.first(where: { $0.id == iPadAppState.selectedHostId }),
              let worktree = iPadAppState.latestWorktrees.first(where: { $0.path == iPadAppState.selectedWorktreePath }),
              let pane = iPadAppState.focusedPaneId else { return }
        iPadAppState.recentPanes.record(hostID: host.id, hostLabel: host.label, worktree: worktree, sessionName: pane)
    }

    private func openContextWorktree(_ path: String, source: WorktreePanes, hostID: UUID?) -> Bool {
        guard scenePhase == .active, gate.state == .unlocked,
              let hostID, hostID == iPadAppState.selectedHostId,
              let host = hostStore.hosts.first(where: { $0.id == hostID }),
              source.path == iPadAppState.selectedWorktreePath
        else { return false }
        let intent = navigationIntent.begin()
        let openingID = UUID()
        notificationPaneActivation.cancel()
        recentPaneOpeningID = openingID
        if let pending = notifications.pendingRoute { notifications.consume(pending) }
        let initialPath = navigationPath
        let initialSelection = notificationSelection
        Task { @MainActor in
            @MainActor func isCurrent() -> Bool {
                navigationIntent.isCurrent(intent) && recentPaneOpeningID == openingID
                    && scenePhase == .active && gate.state == .unlocked
                    && navigationPath == initialPath && notificationSelection == initialSelection
            }
            defer { if recentPaneOpeningID == openingID { recentPaneOpeningID = nil } }
            do {
                let target = try await WorktreeContextActions.resolve(path, source: source, fetch: {
                    try await fetchWorktrees(on: host)
                }, reopen: { path in
                    try await reopenWorktree(path, on: host, notReady: WorktreeContextActions.Failure.notReady)
                }, isCurrent: isCurrent)
                guard isCurrent() else { return }
                iPadAppState.latestWorktrees = target.rows
                if let path = Self.applyContextWorktree(target.worktree, host: host, appState: iPadAppState,
                        compact: horizontalSizeClass != .regular, showsProjectRail: showsProjectRail) {
                    navigationPath = path
                }
            } catch is CancellationError {
            } catch {
                guard isCurrent() else { return }
                contextWorktreeError = "The worktree couldn't be opened on \(host.label). It may be unavailable or the host may be offline."
            }
        }
        return true
    }

    /// Selects a worktree opened from a context link. Regular width selects
    /// it as the sidebar does, requesting terminal focus; compact width
    /// selects it as a picker tap does, without a focus request (IPAD-8.10),
    /// and returns the rebuilt navigation stack.
    static func applyContextWorktree(_ row: WorktreePanes, host: Host, appState: IPadAppState,
                                     compact: Bool, showsProjectRail: Bool) -> NavigationPath? {
        let project = SidebarProjection.projects([row]).first
        if let project { appState.sidebarNavigation.showProject(project.id) }
        guard compact else {
            IPadRootLayout.applyWorktreeSelection(appState: appState, worktree: row)
            return nil
        }
        var path = NavigationPath()
        path.append(host)
        if showsProjectRail, let project { path.append(ProjectStep(host: host, project: project)) }
        applyCompactWorktreeSelection(row, host: host, project: project, appState: appState, navigationPath: &path)
        return path
    }

    /// A fresh authenticated snapshot for `host`: the interaction host's
    /// injected I/O when present, otherwise the shared coordinator.
    private func fetchWorktrees(on host: Host) async throws -> [WorktreePanes] {
        if let notificationIO { return try await notificationIO.fetch(host) }
        return try await coordinator.worktreePanes(for: host)
    }

    /// Reopens a closed worktree on `host`; a refused open throws `notReady`.
    private func reopenWorktree(_ path: String, on host: Host, notReady: Error) async throws {
        if let notificationIO { return try await notificationIO.reopen(host, path) }
        guard try await coordinator.sendWorktreeManagement(.open(worktreeID: path), to: host) == .ok
        else { throw notReady }
    }

    /// Rebuilds the compact navigation stack from the shared selection; the
    /// regular-width layout reads the selection directly.
    private func syncCompactNavigationToSelection() {
        guard horizontalSizeClass != .regular else { return }
        navigationPath = Self.compactSelection(appState: iPadAppState, hosts: hostStore.hosts,
            showsProjectRail: showsProjectRail)?.path ?? NavigationPath()
    }

    private func openRecentPane(_ entry: MobileRecentPanes.Entry, openingID: UUID) async {
        let requestIntent = navigationIntent.current
        let initialPath = navigationPath
        let initialSelection = notificationSelection
        let initialNotification = notifications.pendingRoute
        func isCurrent() -> Bool {
            navigationIntent.isCurrent(requestIntent) && recentPaneOpeningID == openingID
                && scenePhase == .active && gate.state == .unlocked
                && navigationPath == initialPath && notificationSelection == initialSelection
                && notifications.pendingRoute == initialNotification
        }
        defer { if recentPaneOpeningID == openingID { recentPaneOpeningID = nil } }
        guard isCurrent() else { return }
        guard let host = hostStore.hosts.first(where: { $0.id == entry.hostID }) else {
            iPadAppState.recentPanes.forget(entry)
            recentPaneError = "The host for this pane is no longer paired."
            return
        }
        do {
            let target = try await MobileRecentPanes.resolve(entry, fetch: {
                try await fetchWorktrees(on: host)
            }, reopen: { path in
                try await reopenWorktree(path, on: host, notReady: MobileNotificationActivation.Failure.notReady)
            }, isCurrent: isCurrent)
            guard isCurrent() else { return }
            Self.applyActivationTarget(target, host: host, to: iPadAppState)
            syncCompactNavigationToSelection()
            recordSelectedPane()
        } catch is CancellationError {
        } catch let error as MobileNotificationActivation.Failure {
            guard isCurrent() else { return }
            switch error {
            case .worktreeUnavailable, .paneUnavailable:
                iPadAppState.recentPanes.forget(entry)
                recentPaneError = "This pane is no longer available on \(host.label)."
            case .notReady: recentPaneError = "The worktree hasn't started yet. Try again from the worktree list."
            }
        } catch {
            guard isCurrent() else { return }
            recentPaneError = "Couldn't reconnect to \(host.label). Try again when the host is online."
        }
    }

    /// Selects a resolved notification or recent-pane target: its host,
    /// worktree, pane and project, with the fresh rows it was resolved from.
    static func applyActivationTarget(_ target: MobileNotificationActivation.Target, host: Host, to appState: IPadAppState) {
        appState.latestWorktrees = target.rows
        let project = SidebarProjection.projects([target.worktree]).first
        applyCompactSession(.init(host: host, worktreePath: target.worktree.path,
            sessionName: target.pane.sessionName, title: target.pane.displayTitle, worktreeProject: project), to: appState)
        if let project { appState.sidebarNavigation.showProject(project.id) }
    }

    private func activateNotification() async {
        guard scenePhase == .active, gate.state == .unlocked,
              let route = notifications.pendingRoute else { return }
        let requestIntent = navigationIntent.current
        guard activatingNotificationRoute != route || activatingNotificationIntent != requestIntent else { return }
        activatingNotificationRoute = route
        activatingNotificationIntent = requestIntent
        let initialPath = navigationPath
        let initialSelection = notificationSelection
        func isCurrent() -> Bool {
            navigationIntent.isCurrent(requestIntent) && scenePhase == .active
                && gate.state == .unlocked && notifications.pendingRoute == route
                && navigationPath == initialPath && notificationSelection == initialSelection
        }
        defer {
            if activatingNotificationIntent == requestIntent {
                activatingNotificationRoute = nil
                activatingNotificationIntent = nil
            }
            // Newer navigation supersedes the tap even if reconnecting throws.
            if navigationIntent.isCurrent(requestIntent),
               navigationPath != initialPath || notificationSelection != initialSelection { notifications.consume(route) }
        }
        await hostStore.loadIfNeeded()
        guard !Task.isCancelled, isCurrent() else { return }
        guard let host = hostStore.hosts.first(where: { $0.id == route.hostID }) else {
            notifications.consume(route)
            notificationError = "The host for this notification is no longer paired."
            return
        }
        do {
            let target = try await MobileNotificationActivation.resolve(route, fetch: {
                try await fetchWorktrees(on: host)
            }, reopen: { path in
                try await reopenWorktree(path, on: host, notReady: MobileNotificationActivation.Failure.notReady)
            }, isCurrent: isCurrent)
            Self.applyActivationTarget(target, host: host, to: iPadAppState)
            syncCompactNavigationToSelection()
            notificationActivationPath = horizontalSizeClass == .regular ? nil : navigationPath
            notificationPaneActivation.activate(hostID: host.id, sessionName: target.pane.sessionName)
            notifications.consume(route)
        } catch is CancellationError {
            // Lifecycle cancellation retains the tap for the next activation.
        } catch let error as MobileNotificationActivation.Failure {
            guard isCurrent() else { return }
            notifications.consume(route)
            switch error {
            case .worktreeUnavailable: notificationError = "This worktree is no longer available on \(host.label)."
            case .paneUnavailable: notificationError = "The pane for this notification is no longer available."
            case .notReady: notificationError = "The worktree hasn't started yet. Open it from \(host.label) and try again."
            }
        } catch {
            guard !Task.isCancelled, isCurrent() else { return }
            // A reported failure completes this attempt. A later response for
            // the same target must change pendingRoute and start a fresh fetch.
            notifications.consume(route)
            notificationError = "Couldn't reconnect to \(host.label). Open the host and try again."
        }
    }

    private var notificationSelection: [String?] {
        [iPadAppState.selectedHostId?.uuidString, iPadAppState.selectedWorktreePath,
         iPadAppState.focusedPaneId, iPadAppState.sidebarNavigation.selectedProjectID]
    }

    private func updateConnectionAccess() {
        if scenePhase == .background || gate.state != .unlocked { retainedPanes.suspendAll() }
        coordinator.setConnectionsAllowed(
            scenePhase != .background && gate.state == .unlocked
        )
    }

    @ViewBuilder
    private var compactBody: some View {
        NavigationStack(path: $navigationPath) {
            HostPickerView(
                store: hostStore,
                browser: nearbyMacBrowser
            )
                .navigationDestination(for: Host.self) { host in
                    compactPicker(host: host)
                }
                .navigationDestination(for: ProjectStep.self) { step in
                    compactPicker(host: step.host, project: step.project)
                }
                .navigationDestination(for: WorktreeStep.self) { step in
                    WorktreeDetailView(
                        host: step.host,
                        worktree: step.worktree
                    ) { sessionName in
                        let session = SessionStep(
                            host: step.host,
                            worktreePath: step.worktree.path,
                            sessionName: sessionName,
                            title: step.worktree.layout?.title(for: sessionName) ?? sessionName,
                            worktreeProject: step.project ?? SidebarProjection.projects([step.worktree]).first
                        )
                        Self.applyCompactSession(session, to: iPadAppState)
                        navigationPath.append(session)
                    }
                }
                .navigationDestination(for: SessionStep.self) { step in
                    SingleSessionView(step: step, navigationPath: $navigationPath,
                                      onBackToWorktrees: {
                                          Self.applyCompactBack(step: step, appState: iPadAppState,
                                                                navigationPath: &navigationPath,
                                                                showsProjectRail: showsProjectRail)
                                      },
                                      sidebarNavigation: iPadAppState.sidebarNavigation, retainedPanes: retainedPanes,
                                      remoteConnectionProvider: notificationConnectionProvider)
                        .id(step.paneIdentity)
                        .onAppear {
                            guard horizontalSizeClass != .regular else { return }
                            Self.applyCompactSession(step, to: iPadAppState)
                        }
                }
        }
    }

    private func compactPicker(host: Host, project: SidebarProject? = nil) -> some View {
        WorktreePickerView(
            host: host,
            onSelect: { wt in
                Self.applyCompactWorktreeSelection(wt, host: host, project: project, appState: iPadAppState,
                                                   navigationPath: &navigationPath)
            },
            onSelectPane: { worktree, leaf in
                Self.applyCompactPaneSelection(leaf, in: worktree, host: host, project: project,
                                               appState: iPadAppState, navigationPath: &navigationPath)
            },
            navigation: iPadAppState.sidebarNavigation,
            project: project,
            onSelectWorktreeDetail: { worktree in
                iPadAppState.select(hostID: host.id, worktreePath: worktree.path, paneID: iPadAppState.focusedPaneId)
                navigationPath.append(WorktreeStep(host: host, worktree: worktree, project: project))
            }
        )
        .onAppear { Self.applyCompactHost(host, to: iPadAppState) }
        .task {
            if let project,
               iPadAppState.sidebarNavigation.selectedProjectID != project.id {
                iPadAppState.sidebarNavigation.showProject(project.id)
            }
        }
    }

    struct CompactSelection: Equatable {
        let host: Host
        let project: SidebarProject?
        let worktree: WorktreePanes?
        let session: SessionStep?
        var path: NavigationPath {
            var result = NavigationPath()
            result.append(host)
            if let project { result.append(ProjectStep(host: host, project: project)) }
            if let session { result.append(session) }
            else if let worktree { result.append(WorktreeStep(host: host, worktree: worktree, project: project)) }
            return result
        }
    }

    static func compactSelection(appState: IPadAppState, hosts: [Host], showsProjectRail: Bool = true) -> CompactSelection? {
        guard let host = hosts.first(where: { $0.id == appState.selectedHostId }) else { return nil }
        let worktree = appState.latestWorktrees.first { $0.path == appState.selectedWorktreePath }
        let selectedProjectID = appState.sidebarNavigation.selectedProjectID
        let pickerProject = SidebarProjection.projects(appState.latestWorktrees).first {
                $0.id == selectedProjectID
            }
            ?? appState.worktreePickerProject.flatMap { $0.id == selectedProjectID ? $0 : nil }
            ?? worktree.flatMap { SidebarProjection.projects([$0]).first }
        let project = showsProjectRail ? pickerProject : nil
        let leaf = worktree?.layout?.leaves.first { $0.sessionName == appState.focusedPaneId }
            ?? worktree?.layout?.leaves.first
        let session = leaf.map { SessionStep(host: host, worktreePath: worktree?.path,
            sessionName: $0.sessionName, title: $0.displayTitle,
            worktreeProject: pickerProject) }
        return CompactSelection(host: host, project: project, worktree: worktree, session: session)
    }

    static func applyCompactHost(_ host: Host, to appState: IPadAppState) {
        guard appState.selectedHostId != host.id else { return }
        IPadRootLayout.applyHostSwitch(appState: appState, to: host.id)
    }

    /// Compact picker row tap: select the worktree's first pane and push its
    /// terminal, or the worktree detail when it has no single session.
    static func applyCompactWorktreeSelection(_ wt: WorktreePanes, host: Host, project: SidebarProject?,
                                              appState: IPadAppState, navigationPath: inout NavigationPath) {
        appState.select(hostID: host.id, worktreePath: wt.path, paneID: wt.layout?.leaves.first?.sessionName)
        switch MobileNavigationDecision.decide(layout: wt.layout) {
        case let .session(sessionName, title):
            navigationPath.append(SessionStep(host: host, worktreePath: wt.path, sessionName: sessionName, title: title,
                worktreeProject: project ?? SidebarProjection.projects([wt]).first))
        case .worktreeDetail:
            navigationPath.append(WorktreeStep(host: host, worktree: wt, project: project))
        }
    }

    /// Compact picker pane-row tap: select the pane and push its terminal.
    static func applyCompactPaneSelection(_ leaf: PaneLayoutNode.Leaf, in worktree: WorktreePanes, host: Host,
                                          project: SidebarProject?, appState: IPadAppState,
                                          navigationPath: inout NavigationPath) {
        appState.select(hostID: host.id, worktreePath: worktree.path, paneID: leaf.sessionName)
        if case let .session(sessionName, title) = MobileNavigationDecision.decide(paneRow: leaf) {
            navigationPath.append(SessionStep(host: host, worktreePath: worktree.path, sessionName: sessionName,
                title: title, worktreeProject: project ?? SidebarProjection.projects([worktree]).first))
        }
    }

    static func applyCompactSession(_ step: SessionStep, to appState: IPadAppState) {
        appState.select(hostID: step.host.id, worktreePath: step.worktreePath, paneID: step.sessionName)
        appState.worktreePickerProject = step.worktreeProject
        if let project = step.worktreeProject {
            // Search can open another project's terminal without losing the picker.
            appState.sidebarNavigation.selectedProjectID = project.id
        }
    }

    static func applyCompactBack(step: SessionStep, appState: IPadAppState,
                                 navigationPath: inout NavigationPath, showsProjectRail: Bool) {
        IPadRootLayout.applyBackToWorktrees(appState: appState)
        appState.worktreePickerProject = step.worktreeProject
        if let project = step.worktreeProject {
            appState.sidebarNavigation.selectedProjectID = project.id
            appState.sidebarNavigation.compactShowsProjects = false
        }
        navigationPath = step.worktreePickerPath(showsProjectRail: showsProjectRail)
    }

    private var lockOverlay: some View {
        VStack(spacing: 16) {
            Image("GrafttyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)
            Text("Graftty is locked").font(.title2)
            Button("Unlock") { Task { await gate.authenticate() } }
                .buttonStyle(.borderedProminent)
                .disabled(gate.isAuthenticating || scenePhase != .active)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    nonisolated static func makeWebSocketURL(base: URL, session: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = (base.scheme?.lowercased() == "https") ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "session", value: session),
            // Advertise the iOS client kind through the transport the daemon
            // trusts (`declaredDisplayClientKind`). `URLSessionWebSocketClient`
            // connects with a bare URL (no custom header / User-Agent), so this
            // query param is the only kind signal the server sees. Without it
            // the connection is classified `.web`, the store stamps
            // `ownerKind=.web`, and `SessionClient.isOwner` (which requires
            // `.ios`) is never true — the phone becomes a permanent follower
            // that cannot confirm ownership after Take Control or input
            // takeover.
            URLQueryItem(name: "client", value: "ios"),
        ]
        return components.url ?? base
    }
}

/// @spec IOS-4.38: When a compact mobile project is selected, the application shall push its worktrees as a separate native navigation destination so the system Back button and edge swipe return to the project list.
struct ProjectStep: Hashable {
    let host: Host
    let project: SidebarProject
}

/// Picked a worktree, now show its pane tree.
struct WorktreeStep: Hashable {
    let host: Host
    let worktree: WorktreePanes
    var project: SidebarProject? = nil
}

/// Third-level nav: picked a pane, now show its terminal fullscreen.
struct SessionStep: Hashable {
    let host: Host
    let worktreePath: String?
    let sessionName: String
    let title: String
    /// Retain the originating picker even when a search opens another project.
    let worktreeProject: SidebarProject?

    // Replacing a NavigationPath destination can reuse its SwiftUI state.
    // Keep the mounted client scoped to the same identity as retained panes.
    var paneIdentity: String { host.id.uuidString + ":" + sessionName }

    init(
        host: Host,
        worktreePath: String? = nil,
        sessionName: String,
        title: String,
        worktreeProject: SidebarProject? = nil
    ) {
        self.host = host
        self.worktreePath = worktreePath
        self.sessionName = sessionName
        self.title = title
        self.worktreeProject = worktreeProject
    }

    func worktreePickerPath(showsProjectRail: Bool) -> NavigationPath {
        var path = NavigationPath()
        path.append(host)
        if showsProjectRail, let project = worktreeProject {
            path.append(ProjectStep(host: host, project: project))
        }
        return path
    }
}

extension PaneLayoutNode {
    func title(for sessionName: String) -> String? {
        leaves.first { $0.sessionName == sessionName }?.title
    }
}
#endif
