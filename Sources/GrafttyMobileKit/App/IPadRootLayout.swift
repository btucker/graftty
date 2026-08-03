#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI

/// @spec IPAD-1.1
/// Regular-width iPad layout. NavigationSplitView with a worktree
/// sidebar (host header + WorktreeListContent) and a detail column
/// showing the selected worktree's actual live terminal panes in the same
/// split tree supplied by the Mac.
public struct IPadRootLayout: View {
    public static let paintsTerminalBackgroundBehindSidebar = true

    @Bindable public var hostStore: HostStore
    @Bindable public var appState: IPadAppState
    /// Shared with the compact path's `SingleSessionView` at the
    /// `RootView` level so a host negotiated from either surface is
    /// cached for the other (W3 Task 3).
    public let coordinator: RemoteConnectionCoordinator
    @Bindable public var nearbyMacBrowser: NearbyMacBrowser
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    @State private var paneEnvironment: PaneEnvironment = .empty
    @State private var worktreeListRefreshToken: Int = 0
    @State private var explicitSelectionGeneration: UInt64 = 0
    @State private var pendingMobileSplits: [PendingMobileSplit] = []
    @State private var pendingMobileMutationOrder: [UUID] = []
    @State private var mobileMutationInFlight: UUID?
    @State private var pendingMobileCloses: [PendingMobileClose] = []
    @State private var pendingMobileCreatedFocus: PendingMobileCreatedFocus?
    @State private var pendingMobileCloseProjections:
        [MobileWorktreeKey: PendingMobileCloseProjection] = [:]
    @State private var keybindingSet = MobileGhosttyKeybindingSet.loading

    private struct PendingMobileSplit {
        let id: UUID
        var target: String
        let direction: PaneControlRequest.SplitDirection
        let client: PaneControlClient
        let hostID: UUID?
        let worktreePath: String?
        let selectionGeneration: UInt64
        var existingSessionNames: Set<String>
        var existingSessionOrder: [String]
        var legacySucceeded = false
    }

    private struct PendingMobileClose {
        let id: UUID
        var target: String
        let client: PaneControlClient
        var closeProjection: PaneCloseProjection
        let selectionGeneration: UInt64
        let hostID: UUID?
        let worktreePath: String?
    }

    private struct PendingMobileCreatedFocus {
        let sessionName: String?
        let hostID: UUID?
        let worktreePath: String?
        let selectionGeneration: UInt64
        let projectedSessionOrder: [String]
        let removedSessionName: String?
    }

    private struct MobileWorktreeKey: Hashable {
        let hostID: UUID?
        let worktreePath: String?
    }

    private struct PendingMobileCloseProjection {
        var removedSessionNames: Set<String>
        var projectedSessionOrder: [String]
    }

    public init(
        hostStore: HostStore,
        appState: IPadAppState,
        coordinator: RemoteConnectionCoordinator,
        nearbyMacBrowser: NearbyMacBrowser = NearbyMacBrowser()
    ) {
        self.hostStore = hostStore
        self.appState = appState
        self.coordinator = coordinator
        self.nearbyMacBrowser = nearbyMacBrowser
    }

    private var selectedHost: Host? {
        Self.resolveSelectedHost(from: hostStore.hosts, selectedHostId: appState.selectedHostId)
    }

    public var body: some View {
        // `.balanced` locks in column-style (sidebar permanently to the
        // left of the detail) rather than letting iPad heuristics pick
        // `.prominentDetail` (overlay). `columnVisibility` is bound to
        // appState so the system's sidebar-toggle button can flip it back
        // to `.all` after a user collapse — without the binding there'd
        // be no way to re-show a hidden sidebar.
        ZStack {
            appState.theme.background.ignoresSafeArea()
            NavigationSplitView(columnVisibility: Binding(
                get: { appState.columnVisibility },
                set: { appState.columnVisibility = $0 }
            )) {
                Group {
                    if let host = selectedHost {
                        WorktreeListContent(
                            host: host,
                            theme: appState.theme,
                            selectedWorktreePath: appState.selectedWorktreePath,
                            focusedPaneId: appState.focusedPaneId,
                            includeRemoteWorktrees: coordinator.isPaired(host),
                            isReadyToLoad: LiveSessionReadiness.isActive(
                                scene: scenePhase,
                                gateUnlocked: gate.isUnlocked
                            ),
                            remoteConnectionProvider: makeRemoteConnectionProvider(
                                coordinator: coordinator,
                                host: host,
                                sessionName: "worktree-management"
                            ),
                            remoteSnapshotProvider:
                                makeRemoteWorktreeSnapshotProvider(
                                    coordinator: coordinator,
                                    host: host
                                ),
                            onSelect: { wt in selectWorktree(wt) },
                            onSelectPane: { leaf in selectPane(leaf) },
                            onListChanged: { list in
                                Self.onWorktreeListChanged(
                                    appState: appState,
                                    list: list
                                )
                                reconcileMobileCloseProjections(in: list)
                                resolveLegacyMobileSplit(in: list)
                                applyPendingMobileCreatedFocus(in: list)
                            },
                            externalRefreshToken: worktreeListRefreshToken
                        )
                    } else {
                        Spacer()
                    }
                }
                .themedSidebarSurface(appState.theme)
                // IPAD-1.2: the host menu lives in the sidebar nav bar's
                // `.topBarLeading` slot — adjacent to the system
                // sidebar-toggle button. Originally `.principal`, but the
                // centered placement let the menu expand into the trailing
                // `.primaryAction` (+) item at narrow column widths and
                // overlap it. Leading placement is naturally bounded.
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        HostMenu(
                            selectedHost: selectedHost,
                            hostStore: hostStore,
                            appState: appState,
                            browser: nearbyMacBrowser,
                            coordinator: coordinator
                        )
                    }
                }
                // IPAD-1.12: explicit 1pt trailing border separates the
                // sidebar from the detail column (Mac's NSSplitView draws
                // this automatically; iPad's NavigationSplitView does not).
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(appState.theme.foreground.opacity(0.15))
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                .publishSidebarWidth()
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: appState.sidebarWidth,
                    max: 480
                )
            } detail: {
                IPadDetailColumn(
                    host: selectedHost,
                    appState: appState,
                    coordinator: coordinator,
                    paneEnvironment: paneEnvironment,
                    ghosttyCommandContext: ghosttyCommandContext,
                    onSelectPane: { sessionName in
                        selectPane(sessionName: sessionName)
                    }
                )
                .background(appState.theme.background)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // IPAD-1.8: route the host's ghostty theme through SwiftUI's
        // color scheme so the system-rendered sidebar-toggle button
        // (and other built-in chrome) picks contrast that matches the
        // sidebar text color rather than the OS-level appearance.
        .preferredColorScheme(appState.theme.isDark ? .dark : .light)
        .persistSidebarWidth(to: Binding(
            get: { appState.sidebarWidth },
            set: { appState.sidebarWidth = $0 }
        ))
        .focusedSceneValue(\.mobileGhosttyCommandContext, ghosttyCommandContext)
        .task(id: HostPresentationRefreshKey(
            hostID: selectedHost?.id,
            isReady: LiveSessionReadiness.isActive(
                scene: scenePhase,
                gateUnlocked: gate.isUnlocked
            )
        )) {
            await refreshHostPresentationState()
        }
        .task(id: PaneEnvironmentRefreshKey(
            hostID: selectedHost?.id,
            isReady: LiveSessionReadiness.isActive(
                scene: scenePhase,
                gateUnlocked: gate.isUnlocked
            )
        )) {
            await refreshPaneEnvironment()
        }
        .onDisappear {
            Task {
                await paneEnvironment.close()
            }
        }
        .onChange(of: appState.selectedHostId) { _, _ in
            explicitSelectionGeneration &+= 1
            pendingMobileSplits.removeAll()
            pendingMobileCloses.removeAll()
            pendingMobileMutationOrder.removeAll()
            mobileMutationInFlight = nil
            pendingMobileCreatedFocus = nil
        }
    }

    // MARK: - Selection helpers (static for testability)

    static func resolveSelectedHost(from hosts: [Host], selectedHostId: UUID?) -> Host? {
        guard let id = selectedHostId else { return nil }
        return hosts.first { $0.id == id }
    }

    static func resolveSelectedWorktree(
        from worktrees: [WorktreePanes],
        selectedPath: String?
    ) -> WorktreePanes? {
        guard let selectedPath else { return nil }
        return worktrees.first { $0.path == selectedPath }
    }

    static func applyHostSwitch(appState: IPadAppState, to newHostId: UUID) {
        appState.selectedHostId = newHostId
        appState.selectedWorktreePath = nil
        appState.focusedPaneId = nil
        appState.latestWorktrees = []
        appState.anyWorktreeHasAttention = false
    }

    static func onWorktreeListChanged(appState: IPadAppState, list: [WorktreePanes]) {
        appState.latestWorktrees = list

        // Clear a stale selection whose path vanished server-side.
        if let path = appState.selectedWorktreePath,
           !list.contains(where: { $0.path == path }) {
            appState.selectedWorktreePath = nil
            appState.focusedPaneId = nil
        }
        // IPAD-1.17: the selected worktree is still present, but its focused
        // pane was closed/renamed on the host — fall back to the first leaf
        // (or nil when the worktree has no panes) rather than leaving
        // focusedPaneId pointing at a dead sessionName.
        if let path = appState.selectedWorktreePath,
           let wt = list.first(where: { $0.path == path }),
           let pane = appState.focusedPaneId {
            let leaves = wt.layout?.leaves ?? []
            if !leaves.contains(where: { $0.sessionName == pane }) {
                let fallback = leaves.first?.sessionName
                // Guard the write so unchanged values don't bump
                // `@Observable` invalidation on every polling snapshot.
                if appState.focusedPaneId != fallback {
                    appState.focusedPaneId = fallback
                }
            }
        }
        // IPAD-1.11: recompute the "anything needs attention?" flag from
        // worktree-scoped and pane-scoped attention text. The detail-
        // column toolbar reads this to decide whether to surface a
        // collapsed-sidebar attention indicator.
        appState.anyWorktreeHasAttention = list.contains { wt in
            if wt.attentionText != nil { return true }
            return wt.layout?.leaves.contains { $0.attentionText != nil } ?? false
        }
    }

    static func applyWorktreeSelection(appState: IPadAppState, worktree: WorktreePanes) {
        guard !worktree.state.isInFlight else { return }
        appState.selectedWorktreePath = worktree.path
        appState.focusedPaneId = worktree.layout?.leaves.first?.sessionName
        appState.requestActiveTerminal()
    }

    static func applyPaneSelection(appState: IPadAppState, leaf: PaneLayoutNode.Leaf) {
        if let worktree = appState.latestWorktrees.first(where: { wt in
            wt.layout?.leaves.contains { $0.sessionName == leaf.sessionName } ?? false
        }) {
            appState.selectedWorktreePath = worktree.path
        }
        appState.focusedPaneId = leaf.sessionName
        appState.requestActiveTerminal()
    }

    public static func availableSplitDirections(
        focusedPaneId: String?,
        paneControlAvailable: Bool = true
    ) -> [PaneControlRequest.SplitDirection] {
        guard focusedPaneId != nil, paneControlAvailable else { return [] }
        return [.right, .down, .left, .up]
    }

    static func shouldApplySplitCreatedFocus(
        capturedHostID: UUID?,
        capturedWorktreePath: String?,
        capturedSelectionGeneration: UInt64,
        currentHostID: UUID?,
        currentWorktreePath: String?,
        currentSelectionGeneration: UInt64
    ) -> Bool {
        capturedHostID == currentHostID
            && capturedWorktreePath == currentWorktreePath
            && capturedSelectionGeneration == currentSelectionGeneration
    }

    static func rebasedSplitTarget(
        _ target: String,
        completedTarget: String,
        createdSessionName: String
    ) -> String {
        target == completedTarget ? createdSessionName : target
    }

    static func resolvedCreatedFocus(
        sessionName: String,
        worktreePath: String?,
        in worktrees: [WorktreePanes]
    ) -> String? {
        guard let worktree = worktrees.first(where: {
            $0.path == worktreePath
        }),
        worktree.layout?.leaves.contains(where: {
            $0.sessionName == sessionName
        }) == true else {
            return nil
        }
        return sessionName
    }

    static func legacyCreatedSessionName(
        existingSessionNames: Set<String>,
        worktreePath: String?,
        in worktrees: [WorktreePanes]
    ) -> String? {
        guard let worktree = worktrees.first(where: {
            $0.path == worktreePath
        }) else {
            return nil
        }
        return worktree.layout?.leaves.lazy.map(\.sessionName).first {
            !existingSessionNames.contains($0)
        }
    }

    public static func commandKind(for action: GhosttyAction) -> GhosttyCommandKind? {
        guard let entry = GhosttyCommandRegistry[action],
              entry.isSupportedOniPad,
              entry.kind != .unsupported else {
            return nil
        }
        return entry.kind
    }

    static func keybindingSetForStartingHostRefresh() -> MobileGhosttyKeybindingSet {
        .loading
    }

    static func keybindingSet(
        for presentation: RemoteHostPresentation?
    ) -> MobileGhosttyKeybindingSet {
        presentation.map {
            GhosttyKeybindingsFetcher.pairedPresentation($0.keybindings)
        } ?? .bundledFallback
    }

    // MARK: - Side-effecting selection (callbacks from WorktreeListContent)

    private func selectWorktree(_ wt: WorktreePanes) {
        explicitSelectionGeneration &+= 1
        Self.applyWorktreeSelection(appState: appState, worktree: wt)
        applySelectedMobileCloseProjection()
    }

    private func selectPane(_ leaf: PaneLayoutNode.Leaf) {
        explicitSelectionGeneration &+= 1
        Self.applyPaneSelection(appState: appState, leaf: leaf)
        applySelectedMobileCloseProjection()
    }

    private func selectPane(sessionName: String) {
        guard let leaf = selectedWorktreeLayout?.leaves.first(where: {
            $0.sessionName == sessionName
        }) else {
            return
        }
        selectPane(leaf)
    }

    private func selectWorktree(path: String) {
        guard let wt = appState.latestWorktrees.first(where: { $0.path == path }) else { return }
        selectWorktree(wt)
    }

    private func navigateWorktree(forward: Bool) {
        guard let path = IPadWorktreeNavigation.nextPath(
            in: appState.latestWorktrees,
            selectedPath: appState.selectedWorktreePath,
            forward: forward
        ) else {
            return
        }
        selectWorktree(path: path)
    }

    private var ghosttyCommandContext: MobileGhosttyCommandContext {
        MobileGhosttyCommandContext(
            keybindingSet: keybindingSet,
            perform: { semantic in
                performMobileCommand(semantic)
            },
            isEnabled: { action in
                isGhosttyCommandEnabled(action)
            }
        )
    }

    private func performMobileCommand(_ semantic: MobileGhosttyCommandSemantic) {
        switch semantic {
        case let .ghostty(action):
            performGhosttyCommand(action)
        case let .navigateWorktree(forward):
            navigateWorktree(forward: forward)
        }
    }

    private var selectedWorktreeLayout: PaneLayoutNode? {
        Self.resolveSelectedWorktree(
            from: appState.latestWorktrees,
            selectedPath: appState.selectedWorktreePath
        )?.layout
    }

    private func applySelectedMobileCloseProjection() {
        guard let closeProjection = selectedMobileCloseProjection else {
            return
        }
        if appState.focusedPaneId.flatMap({
            closeProjection.projectedSessionOrder.contains($0) ? $0 : nil
        }) == nil {
            appState.focusedPaneId =
                closeProjection.projectedSessionOrder.first
        }
    }

    private func performGhosttyCommand(_ action: GhosttyAction) {
        guard let kind = Self.commandKind(for: action) else { return }
        switch kind {
        case let .split(direction):
            queueSplitFocusedPane(
                Self.paneControlSplitDirection(for: direction)
            )
        case .closePane:
            queueCloseFocusedPane()
        case let .focusPane(direction):
            focusPane(Self.paneLayoutDirection(for: direction))
        case let .focusPaneByOrder(forward):
            focusPaneInOrder(forward: forward)
        case .unsupported:
            break
        }
    }

    private func isGhosttyCommandEnabled(_ action: GhosttyAction) -> Bool {
        guard let kind = Self.commandKind(for: action) else { return false }
        switch kind {
        case .split, .closePane:
            return appState.focusedPaneId != nil && paneEnvironment.paneControlClient != nil
        case let .focusPane(direction):
            guard let layout = selectedWorktreeLayout,
                  let pane = appState.focusedPaneId else {
                return false
            }
            return PaneLayoutNavigation.spatialNeighbor(
                in: layout,
                of: pane,
                direction: Self.paneLayoutDirection(for: direction),
                excluding: selectedMobileRemovedSessionNames
            ) != nil
        case let .focusPaneByOrder(forward):
            guard let layout = selectedWorktreeLayout,
                  let pane = appState.focusedPaneId else {
                return false
            }
            return PaneLayoutNavigation.nextInOrder(
                in: layout,
                from: pane,
                forward: forward,
                excluding: selectedMobileRemovedSessionNames
            ) != nil
        case .unsupported:
            return false
        }
    }

    private func focusPane(_ direction: PaneLayoutNavigation.Direction) {
        guard let layout = selectedWorktreeLayout,
              let pane = appState.focusedPaneId,
              let next = PaneLayoutNavigation.spatialNeighbor(
                in: layout,
                of: pane,
                direction: direction,
                excluding: selectedMobileRemovedSessionNames
              ) else {
            return
        }
        appState.focusedPaneId = next
        explicitSelectionGeneration &+= 1
        appState.requestActiveTerminal()
    }

    private func focusPaneInOrder(forward: Bool) {
        guard let layout = selectedWorktreeLayout,
              let pane = appState.focusedPaneId,
              let next = PaneLayoutNavigation.nextInOrder(
                in: layout,
                from: pane,
                forward: forward,
                excluding: selectedMobileRemovedSessionNames
              ) else {
            return
        }
        appState.focusedPaneId = next
        explicitSelectionGeneration &+= 1
        appState.requestActiveTerminal()
    }

    private func queueSplitFocusedPane(
        _ direction: PaneControlRequest.SplitDirection
    ) {
        guard let target = effectiveMobilePaneControlTarget,
              let client = paneEnvironment.paneControlClient else {
            return
        }
        let sessionOrder = effectiveMobileSessionOrder
        let id = UUID()
        pendingMobileSplits.append(PendingMobileSplit(
            id: id,
            target: target,
            direction: direction,
            client: client,
            hostID: appState.selectedHostId,
            worktreePath: appState.selectedWorktreePath,
            selectionGeneration: explicitSelectionGeneration,
            existingSessionNames: Set(sessionOrder),
            existingSessionOrder: sessionOrder
        ))
        pendingMobileMutationOrder.append(id)
        dispatchNextMobileMutation()
    }

    private func dispatchNextMobileMutation() {
        guard mobileMutationInFlight == nil,
              let id = pendingMobileMutationOrder.first else {
            return
        }
        if let pending = pendingMobileSplits.first(where: { $0.id == id }) {
            dispatchMobileSplit(pending)
        } else if let pending = pendingMobileCloses.first(where: {
            $0.id == id
        }) {
            dispatchMobileClose(pending)
        } else {
            pendingMobileMutationOrder.removeFirst()
            dispatchNextMobileMutation()
        }
    }

    private func dispatchMobileSplit(_ pending: PendingMobileSplit) {
        mobileMutationInFlight = pending.id
        Task { @MainActor in
            let response: PaneControlResponse?
            do {
                response = try await pending.client.split(
                    target: pending.target,
                    direction: pending.direction
                )
            } catch {
                response = nil
            }
            guard let index = pendingMobileSplits.firstIndex(
                where: { $0.id == pending.id }
            ) else {
                if mobileMutationInFlight == pending.id {
                    mobileMutationInFlight = nil
                    dispatchNextMobileMutation()
                }
                return
            }
            switch response {
            case .splitCreated(let sessionName):
                let completed = pendingMobileSplits.remove(at: index)
                pendingMobileMutationOrder.removeAll { $0 == pending.id }
                mobileMutationInFlight = nil
                completeMobileSplit(
                    completed,
                    createdSessionName: sessionName,
                    worktrees: appState.latestWorktrees
                )
                worktreeListRefreshToken &+= 1
                dispatchNextMobileMutation()
            case .ok:
                // Released hosts cannot return the created session. Keep
                // this split as the sole in-flight mutation until a panes
                // snapshot identifies its new leaf.
                pendingMobileSplits[index].legacySucceeded = true
                worktreeListRefreshToken &+= 1
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    guard mobileMutationInFlight == pending.id,
                          pendingMobileSplits.contains(where: {
                              $0.id == pending.id && $0.legacySucceeded
                          }) else {
                        return
                    }
                    // A host switch, failed polling connection, or a peer
                    // that never publishes the mutation must not block all
                    // later pane controls forever. Only this worktree's
                    // batch is unsafe to rebase; commands for another
                    // worktree on the same host remain valid.
                    let doomedIDs = Set(
                        pendingMobileSplits.filter {
                            $0.hostID == pending.hostID
                                && $0.worktreePath == pending.worktreePath
                        }.map(\.id)
                        + pendingMobileCloses.filter {
                            $0.hostID == pending.hostID
                                && $0.worktreePath == pending.worktreePath
                        }.map(\.id)
                    )
                    pendingMobileSplits.removeAll {
                        doomedIDs.contains($0.id)
                    }
                    pendingMobileCloses.removeAll {
                        doomedIDs.contains($0.id)
                    }
                    pendingMobileMutationOrder.removeAll {
                        doomedIDs.contains($0)
                    }
                    if pendingMobileCreatedFocus?.hostID == pending.hostID,
                       pendingMobileCreatedFocus?.worktreePath
                        == pending.worktreePath {
                        pendingMobileCreatedFocus = nil
                    }
                    mobileMutationInFlight = nil
                    dispatchNextMobileMutation()
                }
            case .error, nil:
                pendingMobileSplits.remove(at: index)
                pendingMobileMutationOrder.removeAll { $0 == pending.id }
                mobileMutationInFlight = nil
                dispatchNextMobileMutation()
            }
        }
    }

    private func resolveLegacyMobileSplit(in worktrees: [WorktreePanes]) {
        guard let inFlightID = mobileMutationInFlight,
              let index = pendingMobileSplits.firstIndex(where: {
                  $0.id == inFlightID && $0.legacySucceeded
              }),
              pendingMobileSplits[index].hostID == appState.selectedHostId,
              let worktree = worktrees.first(where: {
                  $0.path == pendingMobileSplits[index].worktreePath
              }),
              (pendingMobileCloseProjections[MobileWorktreeKey(
                  hostID: pendingMobileSplits[index].hostID,
                  worktreePath: pendingMobileSplits[index].worktreePath
              )]?.removedSessionNames.isDisjoint(
                  with: Set(
                      worktree.layout?.leaves.map(\.sessionName) ?? []
                  )
              ) ?? true),
              let createdSessionName = Self.legacyCreatedSessionName(
                existingSessionNames:
                    pendingMobileSplits[index].existingSessionNames,
                worktreePath: pendingMobileSplits[index].worktreePath,
                in: worktrees
              ) else {
            return
        }
        let completed = pendingMobileSplits.remove(at: index)
        pendingMobileMutationOrder.removeAll { $0 == inFlightID }
        mobileMutationInFlight = nil
        completeMobileSplit(
            completed,
            createdSessionName: createdSessionName,
            worktrees: worktrees
        )
        dispatchNextMobileMutation()
    }

    private func completeMobileSplit(
        _ completed: PendingMobileSplit,
        createdSessionName: String,
        worktrees: [WorktreePanes]
    ) {
        for index in pendingMobileSplits.indices
        where pendingMobileSplits[index].hostID == completed.hostID
            && pendingMobileSplits[index].worktreePath
                == completed.worktreePath {
            if pendingMobileSplits[index].selectionGeneration
                == completed.selectionGeneration {
                pendingMobileSplits[index].target = Self.rebasedSplitTarget(
                    pendingMobileSplits[index].target,
                    completedTarget: completed.target,
                    createdSessionName: createdSessionName
                )
            }
            pendingMobileSplits[index].existingSessionNames.insert(
                createdSessionName
            )
            pendingMobileSplits[index].existingSessionOrder =
                PaneCloseProjection.sessionOrder(
                    pendingMobileSplits[index].existingSessionOrder,
                    afterSplitting: completed.target,
                    created: createdSessionName,
                    direction: completed.direction
                )
        }
        for index in pendingMobileCloses.indices
        where pendingMobileCloses[index].hostID == completed.hostID
            && pendingMobileCloses[index].worktreePath
                == completed.worktreePath {
            pendingMobileCloses[index].closeProjection.projectSplit(
                from: completed.target,
                to: createdSessionName,
                direction: completed.direction,
                inheritsFocus:
                    pendingMobileCloses[index].selectionGeneration
                        == completed.selectionGeneration
            )
            pendingMobileCloses[index].target =
                pendingMobileCloses[index].closeProjection.target
        }
        let projectedSessionOrder = PaneCloseProjection.sessionOrder(
            completed.existingSessionOrder,
            afterSplitting: completed.target,
            created: createdSessionName,
            direction: completed.direction
        )
        let completedWorktreeKey = MobileWorktreeKey(
            hostID: completed.hostID,
            worktreePath: completed.worktreePath
        )
        if var closeProjection =
            pendingMobileCloseProjections[completedWorktreeKey] {
            closeProjection.projectedSessionOrder =
                PaneCloseProjection.sessionOrder(
                    closeProjection.projectedSessionOrder,
                    afterSplitting: completed.target,
                    created: createdSessionName,
                    direction: completed.direction
                ).filter {
                    !closeProjection.removedSessionNames.contains($0)
                }
            pendingMobileCloseProjections[completedWorktreeKey] =
                closeProjection
        }
        if Self.shouldApplySplitCreatedFocus(
            capturedHostID: completed.hostID,
            capturedWorktreePath: completed.worktreePath,
            capturedSelectionGeneration: completed.selectionGeneration,
            currentHostID: appState.selectedHostId,
            currentWorktreePath: appState.selectedWorktreePath,
            currentSelectionGeneration: explicitSelectionGeneration
        ) {
            pendingMobileCreatedFocus = PendingMobileCreatedFocus(
                sessionName: createdSessionName,
                hostID: completed.hostID,
                worktreePath: completed.worktreePath,
                selectionGeneration: completed.selectionGeneration,
                projectedSessionOrder: projectedSessionOrder,
                removedSessionName: nil
            )
            applyPendingMobileCreatedFocus(in: worktrees)
        }
    }

    private func applyPendingMobileCreatedFocus(
        in worktrees: [WorktreePanes]
    ) {
        guard let pending = pendingMobileCreatedFocus else { return }
        guard Self.shouldApplySplitCreatedFocus(
            capturedHostID: pending.hostID,
            capturedWorktreePath: pending.worktreePath,
            capturedSelectionGeneration: pending.selectionGeneration,
            currentHostID: appState.selectedHostId,
            currentWorktreePath: appState.selectedWorktreePath,
            currentSelectionGeneration: explicitSelectionGeneration
        ) else {
            pendingMobileCreatedFocus = nil
            return
        }
        guard let worktree = worktrees.first(where: {
            $0.path == pending.worktreePath
        }) else {
            return
        }
        let sessionNames = worktree.layout?.leaves.map(\.sessionName) ?? []
        if let removedSessionName = pending.removedSessionName,
           sessionNames.contains(removedSessionName) {
            // A replacement can already exist in a stale snapshot. Keep
            // the projected focus/order until the closed pane is actually
            // absent so a repeated close cannot select that dead pane.
            return
        }
        let resolvedSessionName: String?
        if let sessionName = pending.sessionName,
           sessionNames.contains(sessionName) {
            resolvedSessionName = sessionName
        } else if pending.removedSessionName != nil {
            // A concurrent host-side close can remove the projected
            // replacement too. Once the original removal is authoritative,
            // fall back to the first live pane instead of retaining a
            // speculative target forever.
            resolvedSessionName = sessionNames.first
        } else {
            return
        }
        appState.focusedPaneId = resolvedSessionName
        pendingMobileCreatedFocus = nil
        if resolvedSessionName != nil {
            appState.requestActiveTerminal()
        }
    }

    private var effectiveMobilePaneControlTarget: String? {
        if let closeProjection = selectedMobileCloseProjection {
            if let pending = pendingMobileCreatedFocus,
               pendingMobileFocusIsCurrent(pending),
               let sessionName = pending.sessionName,
               closeProjection.projectedSessionOrder.contains(sessionName) {
                return sessionName
            }
            if let focusedPaneID = appState.focusedPaneId,
               closeProjection.projectedSessionOrder.contains(
                   focusedPaneID
               ) {
                return focusedPaneID
            }
            return closeProjection.projectedSessionOrder.first
        }
        if let pending = pendingMobileCreatedFocus,
           pendingMobileFocusIsCurrent(pending) {
            return pending.sessionName
        }
        return appState.focusedPaneId
    }

    private var effectiveMobileSessionOrder: [String] {
        if let closeProjection = selectedMobileCloseProjection {
            return closeProjection.projectedSessionOrder
        }
        if let pending = pendingMobileCreatedFocus,
           pendingMobileFocusIsCurrent(pending) {
            return pending.projectedSessionOrder
        }
        return selectedWorktreeLayout?.leaves.map(\.sessionName) ?? []
    }

    private var selectedMobileCloseProjection:
        PendingMobileCloseProjection? {
        pendingMobileCloseProjections[MobileWorktreeKey(
            hostID: appState.selectedHostId,
            worktreePath: appState.selectedWorktreePath
        )]
    }

    private var selectedMobileRemovedSessionNames: Set<String> {
        selectedMobileCloseProjection?.removedSessionNames ?? []
    }

    private func pendingMobileFocusIsCurrent(
        _ pending: PendingMobileCreatedFocus
    ) -> Bool {
        Self.shouldApplySplitCreatedFocus(
            capturedHostID: pending.hostID,
            capturedWorktreePath: pending.worktreePath,
            capturedSelectionGeneration: pending.selectionGeneration,
            currentHostID: appState.selectedHostId,
            currentWorktreePath: appState.selectedWorktreePath,
            currentSelectionGeneration: explicitSelectionGeneration
        )
    }

    private func reconcileMobileCloseProjections(
        in worktrees: [WorktreePanes]
    ) {
        let hostID = appState.selectedHostId
        let matchingKeys = pendingMobileCloseProjections.keys.filter {
            $0.hostID == hostID
        }
        for key in matchingKeys {
            guard let projection = pendingMobileCloseProjections[key] else {
                continue
            }
            let sessionNames = Set(
                worktrees.first(where: {
                    $0.path == key.worktreePath
                })?.layout?.leaves.map(\.sessionName) ?? []
            )
            if projection.removedSessionNames.isDisjoint(
                with: sessionNames
            ) {
                pendingMobileCloseProjections[key] = nil
                continue
            }
            guard key.worktreePath == appState.selectedWorktreePath else {
                continue
            }
            if appState.focusedPaneId.flatMap({
                projection.projectedSessionOrder.contains($0) ? $0 : nil
            }) == nil {
                appState.focusedPaneId =
                    projection.projectedSessionOrder.first
            }
        }
    }

    private func queueCloseFocusedPane() {
        guard let target = effectiveMobilePaneControlTarget,
              let client = paneEnvironment.paneControlClient else {
            return
        }
        let id = UUID()
        let closeProjection = PaneCloseProjection(
            target: target,
            sessionOrder: effectiveMobileSessionOrder
        )
        pendingMobileCloses.append(PendingMobileClose(
            id: id,
            target: target,
            client: client,
            closeProjection: closeProjection,
            selectionGeneration: explicitSelectionGeneration,
            hostID: appState.selectedHostId,
            worktreePath: appState.selectedWorktreePath
        ))
        pendingMobileMutationOrder.append(id)
        dispatchNextMobileMutation()
    }

    private func dispatchMobileClose(_ pending: PendingMobileClose) {
        mobileMutationInFlight = pending.id
        Task { @MainActor in
            let response: PaneControlResponse?
            do {
                response = try await pending.client.close(
                    target: pending.target
                )
            } catch {
                response = nil
            }
            guard let index = pendingMobileCloses.firstIndex(where: {
                $0.id == pending.id
            }) else {
                if mobileMutationInFlight == pending.id {
                    mobileMutationInFlight = nil
                    dispatchNextMobileMutation()
                }
                return
            }
            pendingMobileCloses.remove(at: index)
            pendingMobileMutationOrder.removeAll { $0 == pending.id }
            mobileMutationInFlight = nil
            if response?.isSuccess == true {
                let replacement = pending.closeProjection.replacementTarget
                let worktreeKey = MobileWorktreeKey(
                    hostID: pending.hostID,
                    worktreePath: pending.worktreePath
                )
                var closeProjection = pendingMobileCloseProjections[
                    worktreeKey
                ] ?? PendingMobileCloseProjection(
                    removedSessionNames: [],
                    projectedSessionOrder:
                        pending.closeProjection.sessionOrder
                )
                closeProjection.removedSessionNames.insert(pending.target)
                closeProjection.projectedSessionOrder =
                    pending.closeProjection.sessionOrder.filter {
                        !closeProjection.removedSessionNames.contains($0)
                    }
                pendingMobileCloseProjections[worktreeKey] = closeProjection
                if pending.hostID == appState.selectedHostId,
                   pending.worktreePath == appState.selectedWorktreePath {
                    let currentGeneration = explicitSelectionGeneration
                    let currentTarget = effectiveMobilePaneControlTarget
                    let projectedSessionOrder =
                        closeProjection.projectedSessionOrder
                    let projectedTarget: String?
                    if currentTarget == pending.target {
                        projectedTarget = projectedSessionOrder.first
                    } else if let currentTarget,
                              projectedSessionOrder.contains(currentTarget) {
                        projectedTarget = currentTarget
                    } else {
                        projectedTarget = nil
                    }
                    pendingMobileCreatedFocus = PendingMobileCreatedFocus(
                        sessionName: projectedTarget,
                        hostID: pending.hostID,
                        worktreePath: pending.worktreePath,
                        selectionGeneration: currentGeneration,
                        projectedSessionOrder: projectedSessionOrder,
                        removedSessionName: pending.target
                    )
                    // Match local focus immediately, including disabling
                    // controls when the final pane closed. The token stays
                    // alive until polling proves the closed pane is absent.
                    appState.focusedPaneId = projectedTarget
                    applyPendingMobileCreatedFocus(
                        in: appState.latestWorktrees
                    )
                }
                if let replacement {
                    for index in pendingMobileSplits.indices
                    where pendingMobileSplits[index].hostID
                        == pending.hostID
                        && pendingMobileSplits[index].worktreePath
                            == pending.worktreePath {
                        pendingMobileSplits[index].target =
                            Self.rebasedSplitTarget(
                                pendingMobileSplits[index].target,
                                completedTarget: pending.target,
                                createdSessionName: replacement
                            )
                        pendingMobileSplits[index].existingSessionOrder
                            .removeAll { $0 == pending.target }
                    }
                }
                for index in pendingMobileCloses.indices
                where pendingMobileCloses[index].hostID == pending.hostID
                    && pendingMobileCloses[index].worktreePath
                        == pending.worktreePath {
                    pendingMobileCloses[index].closeProjection
                        .projectClose(
                            from: pending.target,
                            to: replacement,
                            inheritsFocus: true
                        )
                    pendingMobileCloses[index].target =
                        pendingMobileCloses[index].closeProjection.target
                }
                if replacement == nil {
                    let doomedIDs = Set(
                        pendingMobileSplits.filter {
                            $0.hostID == pending.hostID
                                && $0.worktreePath
                                    == pending.worktreePath
                                && $0.target == pending.target
                        }.map(\.id)
                        + pendingMobileCloses.filter {
                            $0.hostID == pending.hostID
                                && $0.worktreePath
                                    == pending.worktreePath
                                && $0.target == pending.target
                        }.map(\.id)
                    )
                    pendingMobileSplits.removeAll {
                        doomedIDs.contains($0.id)
                    }
                    pendingMobileCloses.removeAll {
                        doomedIDs.contains($0.id)
                    }
                    pendingMobileMutationOrder.removeAll {
                        doomedIDs.contains($0)
                    }
                }
                worktreeListRefreshToken &+= 1
            }
            dispatchNextMobileMutation()
        }
    }

    private static func paneControlSplitDirection(
        for direction: GhosttySplitDirection
    ) -> PaneControlRequest.SplitDirection {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    private static func paneLayoutDirection(
        for direction: GhosttyPaneFocusDirection
    ) -> PaneLayoutNavigation.Direction {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    @MainActor
    private func refreshHostPresentationState() async {
        guard LiveSessionReadiness.isActive(
            scene: scenePhase,
            gateUnlocked: gate.isUnlocked
        ) else {
            return
        }
        guard let host = selectedHost else {
            appState.theme = .fallback
            keybindingSet = Self.keybindingSetForStartingHostRefresh()
            return
        }
        let capturedHostID = host.id
        keybindingSet = Self.keybindingSetForStartingHostRefresh()
        let presentation = await coordinator.presentation(for: host)
        let text = presentation?.ghosttyConfig
        guard !Task.isCancelled else { return }
        guard capturedHostID == appState.selectedHostId else { return }
        appState.theme = text.map(GhosttyThemeColors.init(parsingConfigText:)) ?? .fallback

        let resolvedKeybindingSet = Self.keybindingSet(for: presentation)
        guard !Task.isCancelled else { return }
        guard capturedHostID == appState.selectedHostId else { return }
        keybindingSet = resolvedKeybindingSet
    }

    @MainActor
    private func refreshPaneEnvironment() async {
        guard LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) else {
            await closeAndClearPaneEnvironment()
            return
        }
        guard let host = selectedHost else {
            await closeAndClearPaneEnvironment()
            return
        }

        await closeAndClearPaneEnvironment()
        let capturedHostID = host.id
        let remoteHost = await coordinator.connection(for: host)
        guard !Task.isCancelled else { return }
        guard capturedHostID == appState.selectedHostId else { return }
        let environment = await buildPaneEnvironment(remoteHost: remoteHost)
        // Every guard must sit between the last suspension and the state
        // write: `.task(id:)` cancels this task when the scene backgrounds
        // or the biometric gate locks, and a cancelled task resuming here
        // must not install a live environment over its successor's teardown
        // (nor leave SSH channels open behind the lock).
        guard !Task.isCancelled, capturedHostID == appState.selectedHostId else {
            await environment.close()
            return
        }
        let previous = paneEnvironment
        paneEnvironment = environment
        await previous.close()
    }

    /// Detaches the current environment synchronously (no suspension between
    /// reading and clearing the state) and only then awaits its close, so a
    /// stale task parked inside `close()` can never clobber a successor's
    /// freshly-installed environment when it resumes.
    @MainActor
    private func closeAndClearPaneEnvironment() async {
        let current = paneEnvironment
        paneEnvironment = .empty
        await current.close()
    }
}

private struct PaneEnvironmentRefreshKey: Hashable {
    let hostID: UUID?
    let isReady: Bool
}

private struct HostPresentationRefreshKey: Hashable {
    let hostID: UUID?
    let isReady: Bool
}

// MARK: - HostMenu (private)

/// @spec IPAD-1.2: While `IPadRootLayout` is presented, the sidebar shall display a host-switcher `Menu` in its system navigation bar's `.topBarLeading` placement (not as a row beneath the nav bar) adjacent to the system sidebar-toggle button, showing the selected host's label and a trailing chevron, and tapping it shall present an anchored dropdown containing each saved host (with a checkmark on the currently-selected one) and an "Add Host…" action. Anchoring at the leading edge keeps the menu out of the trailing `+` action item's space even at narrow column widths, and living in the toolbar avoids the column-gesture conflict the previous row-with-Menu had — tapping a Menu wrapped in a tappable row could collapse the sidebar.
private struct HostMenu: View {
    let selectedHost: Host?
    @Bindable var hostStore: HostStore
    @Bindable var appState: IPadAppState
    @Bindable var browser: NearbyMacBrowser
    let coordinator: RemoteConnectionCoordinator

    @State private var showingAddHost = false

    var body: some View {
        Menu {
            // Saved hosts with a checkmark on the currently-selected
            // one; tapping fires the standard host switch (clears
            // worktree selection + focused pane).
            ForEach(hostStore.hosts.filter { coordinator.isPaired($0) }) {
                host in
                Button {
                    IPadRootLayout.applyHostSwitch(appState: appState, to: host.id)
                } label: {
                    if host.id == selectedHost?.id {
                        Label(host.label, systemImage: "checkmark")
                    } else {
                        Text(host.label)
                    }
                }
            }
            if hostStore.hosts.contains(where: { coordinator.isPaired($0) }) {
                Divider()
            }
            Button {
                showingAddHost = true
            } label: {
                Label("Add Host…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedHost?.label ?? "No host")
                    .font(.body.weight(.semibold))
                    // Middle-truncate long host labels so the menu
                    // never crowds the trailing `+` action even at
                    // the sidebar's minimum column width.
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(
                        selectedHost == nil
                            ? appState.theme.foreground.opacity(0.55)
                            : appState.theme.foreground
                    )
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appState.theme.sidebarChevron)
            }
            // Cap the menu's intrinsic width so the host name
            // truncates rather than pushing trailing toolbar items.
            // The system handles spacing from the leading
            // sidebar-toggle automatically when items share
            // `.topBarLeading`.
            .frame(maxWidth: 160, alignment: .leading)
        }
        .sheet(isPresented: $showingAddHost) {
            NavigationStack {
                AddHostView(browser: browser) { host in
                    let savedHost = try hostStore.add(host)
                    // Auto-select the freshly-added host so the sidebar
                    // immediately fetches its worktree list.
                    IPadRootLayout.applyHostSwitch(
                        appState: appState,
                        to: savedHost.id
                    )
                }
            }
        }
        .task { await hostStore.loadIfNeeded() }
    }
}

// MARK: - IPadDetailColumn (private)

private struct IPadDetailColumn: View {
    let host: Host?
    @Bindable var appState: IPadAppState
    let coordinator: RemoteConnectionCoordinator
    /// Still needed after the toolbar splits moved onto
    /// `ghosttyCommandContext`: `shouldShowSplitControls` gates the toolbar
    /// group on `paneControlClient` availability.
    let paneEnvironment: PaneEnvironment
    let ghosttyCommandContext: MobileGhosttyCommandContext
    let onSelectPane: (String) -> Void

    var body: some View {
        content
            // @spec IPAD-2.8
            // Match the Mac window: the terminal tree owns the complete
            // detail-column rectangle and extends beneath transparent
            // navigation chrome. Split controls stay real toolbar commands,
            // but float over the panes instead of shrinking them.
            .ignoresSafeArea(.container, edges: .top)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // IPAD-1.11: the conditional wraps the whole
                // `ToolbarItem` (not just its body) so iOS doesn't
                // reserve a dead leading slot when no attention is set.
                if shouldShowAttentionDot {
                    ToolbarItem(placement: .topBarLeading) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Attention needed in sidebar")
                    }
                }
                if shouldShowSplitControls {
                    // One split implementation: the buttons dispatch through
                    // the same command context as the keyboard shortcuts, so
                    // enablement, refresh, and error semantics can't diverge.
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            ghosttyCommandContext.perform(.ghostty(.newSplitRight))
                        } label: {
                            Label(
                                "Split Right",
                                systemImage: GhosttySplitDirection.right
                                    .filledPaneSystemImageName
                            )
                        }
                        Button {
                            ghosttyCommandContext.perform(.ghostty(.newSplitDown))
                        } label: {
                            Label(
                                "Split Down",
                                systemImage: GhosttySplitDirection.down
                                    .filledPaneSystemImageName
                            )
                        }
                        Button {
                            ghosttyCommandContext.perform(.ghostty(.newSplitLeft))
                        } label: {
                            Label(
                                "Split Left",
                                systemImage: GhosttySplitDirection.left
                                    .filledPaneSystemImageName
                            )
                        }
                        Button {
                            ghosttyCommandContext.perform(.ghostty(.newSplitUp))
                        } label: {
                            Label(
                                "Split Up",
                                systemImage: GhosttySplitDirection.up
                                    .filledPaneSystemImageName
                            )
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if host == nil {
            ContentUnavailableView(
                "Pick a host",
                systemImage: "server.rack",
                description: Text("Tap the chevron at the top of the sidebar.")
            )
        } else if let host, let worktree = selectedWorktree {
            MultiPaneDetailView(
                host: host,
                worktree: worktree,
                coordinator: coordinator,
                theme: appState.theme,
                focusedPaneId: appState.focusedPaneId,
                pendingFocusRequests: appState.pendingFocusRequests,
                onFocusRequestsConsumed: {
                    appState.consumeFocusRequests()
                },
                autoTakeControlRequestCount: appState.ownershipRequestCount,
                autoTakeControlPolicy: appState.autoTakeControlPolicy,
                ghosttyCommandContext: ghosttyCommandContext,
                onSelectPane: onSelectPane
            )
            .id("\(host.id)-\(worktree.path)")
        } else {
            ContentUnavailableView(
                "Pick a worktree",
                systemImage: "list.bullet.indent"
            )
        }
    }

    private var selectedWorktree: WorktreePanes? {
        IPadRootLayout.resolveSelectedWorktree(
            from: appState.latestWorktrees,
            selectedPath: appState.selectedWorktreePath
        )
    }

    private var shouldShowAttentionDot: Bool {
        appState.columnVisibility != .all && appState.anyWorktreeHasAttention
    }

    private var shouldShowSplitControls: Bool {
        host != nil
            && appState.selectedWorktreePath != nil
            && !IPadRootLayout.availableSplitDirections(
                focusedPaneId: appState.focusedPaneId,
                paneControlAvailable: paneEnvironment.paneControlClient != nil
            ).isEmpty
    }
}
#endif
