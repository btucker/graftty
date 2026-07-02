#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// @spec IPAD-1.1
/// Regular-width iPad layout. NavigationSplitView with a worktree
/// sidebar (host header + WorktreeListContent) and a detail column
/// showing the focused pane via SingleSessionView.
public struct IPadRootLayout: View {

    @Bindable public var hostStore: HostStore
    @Bindable public var appState: IPadAppState
    /// Shared with the compact path's `SingleSessionView` at the
    /// `RootView` level so a host negotiated from either surface is
    /// cached for the other (W3 Task 3).
    public let coordinator: RemoteConnectionCoordinator

    public init(hostStore: HostStore, appState: IPadAppState, coordinator: RemoteConnectionCoordinator) {
        self.hostStore = hostStore
        self.appState = appState
        self.coordinator = coordinator
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
                        onSelect: { wt in selectWorktree(wt) },
                        onSelectPane: { leaf in selectPane(leaf) },
                        onListChanged: { list in Self.onWorktreeListChanged(appState: appState, list: list) }
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
                        appState: appState
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
                coordinator: coordinator
            )
            .background(appState.theme.background)
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
        .task(id: selectedHost?.id) {
            await refreshTheme()
        }
    }

    // MARK: - Selection helpers (static for testability)

    static func resolveSelectedHost(from hosts: [Host], selectedHostId: UUID?) -> Host? {
        guard let id = selectedHostId else { return nil }
        return hosts.first { $0.id == id }
    }

    static func applyHostSwitch(appState: IPadAppState, to newHostId: UUID) {
        appState.selectedHostId = newHostId
        appState.selectedWorktreePath = nil
        appState.focusedPaneId = nil
    }

    static func onWorktreeListChanged(appState: IPadAppState, list: [WorktreePanes]) {
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

    // MARK: - Side-effecting selection (callbacks from WorktreeListContent)

    private func selectWorktree(_ wt: WorktreePanes) {
        guard !wt.state.isInFlight else { return }
        appState.selectedWorktreePath = wt.path
        appState.focusedPaneId = wt.layout?.leaves.first?.sessionName
    }

    private func selectPane(_ leaf: PaneLayoutNode.Leaf) {
        appState.focusedPaneId = leaf.sessionName
    }

    @MainActor
    private func refreshTheme() async {
        guard let host = selectedHost else {
            appState.theme = .fallback
            return
        }
        let capturedHostID = host.id
        let text = await GhosttyConfigFetcher.fetch(baseURL: host.baseURL)
        guard !Task.isCancelled else { return }
        guard capturedHostID == appState.selectedHostId else { return }
        appState.theme = text.map(GhosttyThemeColors.init(parsingConfigText:)) ?? .fallback
    }
}

// MARK: - HostMenu (private)

/// @spec IPAD-1.2: While `IPadRootLayout` is presented, the sidebar shall display a host-switcher `Menu` in its system navigation bar's `.topBarLeading` placement (not as a row beneath the nav bar) adjacent to the system sidebar-toggle button, showing the selected host's label and a trailing chevron, and tapping it shall present an anchored dropdown containing each saved host (with a checkmark on the currently-selected one) and an "Add Host…" action. Anchoring at the leading edge keeps the menu out of the trailing `+` action item's space even at narrow column widths, and living in the toolbar avoids the column-gesture conflict the previous row-with-Menu had — tapping a Menu wrapped in a tappable row could collapse the sidebar.
private struct HostMenu: View {
    let selectedHost: Host?
    @Bindable var hostStore: HostStore
    @Bindable var appState: IPadAppState

    @State private var showingAddHost = false

    var body: some View {
        Menu {
            // Saved hosts with a checkmark on the currently-selected
            // one; tapping fires the standard host switch (clears
            // worktree selection + focused pane).
            ForEach(hostStore.hosts) { host in
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
            if !hostStore.hosts.isEmpty {
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
                AddHostView { host in
                    try hostStore.add(host)
                    // Auto-select the freshly-added host so the sidebar
                    // immediately fetches its worktree list.
                    IPadRootLayout.applyHostSwitch(appState: appState, to: host.id)
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

    var body: some View {
        content
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
        } else if let path = appState.selectedWorktreePath,
                  let pane = appState.focusedPaneId,
                  let host {
            SingleSessionView(
                step: SessionStep(host: host, sessionName: pane, title: pane),
                navigationPath: .constant(NavigationPath()),
                isFullScreen: false,
                coordinator: coordinator
            )
            .id("\(host.id)-\(path)-\(pane)")
        } else {
            ContentUnavailableView(
                "Pick a worktree",
                systemImage: "list.bullet.indent"
            )
        }
    }

    private var shouldShowAttentionDot: Bool {
        appState.columnVisibility != .all && appState.anyWorktreeHasAttention
    }
}
#endif
