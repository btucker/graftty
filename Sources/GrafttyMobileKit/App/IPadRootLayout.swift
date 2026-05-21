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

    public init(hostStore: HostStore, appState: IPadAppState) {
        self.hostStore = hostStore
        self.appState = appState
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
            VStack(spacing: 0) {
                HostHeaderRow(
                    selectedHost: selectedHost,
                    hostStore: hostStore,
                    appState: appState
                )
                if let host = selectedHost {
                    WorktreeListContent(
                        host: host,
                        theme: appState.theme,
                        onSelect: { wt in selectWorktree(wt) },
                        onSelectPane: { leaf in selectPane(leaf) },
                        onListChanged: { list in Self.onWorktreeListChanged(appState: appState, list: list) }
                    )
                } else {
                    Spacer()
                }
            }
            .themedSidebarSurface(appState.theme)
            .publishSidebarWidth()
            .navigationSplitViewColumnWidth(
                min: 220,
                ideal: appState.sidebarWidth,
                max: 480
            )
        } detail: {
            IPadDetailColumn(
                host: selectedHost,
                appState: appState
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

// MARK: - HostHeaderRow (private)

/// @spec IPAD-1.2
private struct HostHeaderRow: View {
    let selectedHost: Host?
    @Bindable var hostStore: HostStore
    @Bindable var appState: IPadAppState

    @State private var showingAddHost = false

    var body: some View {
        Menu {
            // Saved hosts as Picker-style buttons with a check mark on
            // the currently-selected one. Tapping a host fires the
            // standard host switch (clears selection + focused pane).
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
            HStack(alignment: .center, spacing: 6) {
                Text(selectedHost?.label ?? "No host")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(
                        selectedHost == nil
                            ? appState.theme.foreground.opacity(0.55)
                            : appState.theme.foreground
                    )
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appState.theme.sidebarChevron)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(appState.theme.background)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
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

    var body: some View {
        content
            .toolbar {
                // IPAD-1.11: when the sidebar is collapsed and any
                // worktree carries attention, surface a red dot in the
                // leading toolbar position alongside the system
                // sidebar-toggle button. Empty `ToolbarItem` when not
                // needed so the toolbar doesn't reserve dead space.
                ToolbarItem(placement: .topBarLeading) {
                    if shouldShowAttentionDot {
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
                isFullScreen: false
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
