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
        NavigationSplitView {
            VStack(spacing: 0) {
                HostHeaderRow(
                    selectedHost: selectedHost,
                    hostStore: hostStore,
                    appState: appState
                )
                if let host = selectedHost {
                    WorktreeListContent(
                        host: host,
                        onSelect: { wt in selectWorktree(wt) },
                        onSelectPane: { leaf in selectPane(leaf) },
                        onListChanged: { list in Self.onWorktreeListChanged(appState: appState, list: list) }
                    )
                } else {
                    Spacer()
                }
            }
            .background(appState.theme.sidebarBackground)
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
        guard let path = appState.selectedWorktreePath else { return }
        if !list.contains(where: { $0.path == path }) {
            appState.selectedWorktreePath = nil
            appState.focusedPaneId = nil
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

    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    if let host = selectedHost {
                        Text(host.label)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(appState.theme.foreground)
                        Text(host.baseURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(appState.theme.foreground.opacity(0.55))
                    } else {
                        Text("No host selected")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(appState.theme.foreground.opacity(0.55))
                        Text("Tap to pick")
                            .font(.caption)
                            .foregroundStyle(appState.theme.foreground.opacity(0.35))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appState.theme.foreground.opacity(0.55))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(appState.theme.background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover) {
            NavigationStack {
                HostPickerView(store: hostStore) { newHost in
                    IPadRootLayout.applyHostSwitch(appState: appState, to: newHost.id)
                    showingPopover = false
                }
            }
            .frame(minWidth: 320, minHeight: 360)
        }
    }
}

// MARK: - IPadDetailColumn (private)

private struct IPadDetailColumn: View {
    let host: Host?
    @Bindable var appState: IPadAppState

    var body: some View {
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
                navigationPath: .constant(NavigationPath())
            )
            .id("\(host.id)-\(path)-\(pane)")
        } else {
            ContentUnavailableView(
                "Pick a worktree",
                systemImage: "list.bullet.indent"
            )
        }
    }
}
#endif
