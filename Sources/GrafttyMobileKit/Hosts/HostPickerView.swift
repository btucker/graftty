#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyRemoteClient

public struct HostPickerView: View {
    private typealias Connections = DownstreamHostConnections<UUID>
    @AppStorage(SidebarLayoutPolicy.projectRailSettingKey) private var showsProjectRail = true
    @Bindable var store: HostStore
    @Bindable var browser: NearbyMacBrowser
    @State private var showingAdd = false
    @State private var forgetError: String?
    @Environment(\.remoteConnectionCoordinator) private var coordinator
    @Environment(\.multiHostFeed) private var feed

    /// When non-nil, tapping a saved-host row fires this callback instead of
    /// using `NavigationLink(value: host)`. Lets the iPad host-switcher
    /// popover reuse this view body without a navigation push.
    public let onSelect: ((Host) -> Void)?

    public init(
        store: HostStore,
        browser: NearbyMacBrowser = NearbyMacBrowser(),
        onSelect: ((Host) -> Void)? = nil
    ) {
        self.store = store
        self.browser = browser
        self.onSelect = onSelect
    }

    private func status(of host: Host) -> String {
        guard let feed else { return "Paired" }
        return feed.state.availability(of: host.id).connectionLabel
    }

    private var downstreamHosts: [Connections.Host] {
        guard let feed else { return [] }
        return feed.hosts.map { .init(id: $0.id, label: $0.label, isConnected: feed.state.isLive($0.id)) }
    }

    public var body: some View {
        List {
            Section("Paired Macs") {
                if store.hasLoaded && store.hosts.isEmpty {
                    Text("No paired Macs yet.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    // Keep one list row per saved host so swipe-to-forget
                    // offsets still refer to store.hosts, not relay children.
                    VStack(alignment: .leading, spacing: 12) {
                        savedHostRow(host)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let feed {
                            DownstreamHostRows(feed: feed, hostID: host.id) { route in
                                Task {
                                    await feed.downstreamConnections.connect(route, send: sendDownstream)
                                    await refreshDownstreamHosts()
                                }
                            }
                            .padding(.leading, 24)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                .onDelete { offsets in
                    let removed = offsets.map { store.hosts[$0] }
                    for host in removed {
                        Task {
                            do {
                                if let coordinator {
                                    try await coordinator.forget(host)
                                }
                                try store.delete(host.id)
                            } catch {
                                forgetError =
                                    "Couldn't forget \(host.label): "
                                    + error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Toggle("Show project rail", isOn: $showsProjectRail)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Display options")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Pair a Mac")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddHostView(browser: browser) { host in try store.add(host) }
        }
        .alert(
            "Couldn't forget Mac",
            isPresented: Binding(
                get: { forgetError != nil },
                set: { if !$0 { forgetError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(forgetError ?? "")
        }
        .alert("Couldn't connect host", isPresented: Binding(
            get: { feed?.downstreamConnections.error != nil },
            set: { if !$0 { feed?.downstreamConnections.error = nil } }
        )) {
            Button("OK", role: .cancel) { feed?.downstreamConnections.error = nil }
        } message: { Text(feed?.downstreamConnections.error ?? "") }
        .task { await store.loadIfNeeded() }
        .task(id: downstreamHosts) {
            guard feed != nil else { return }
            while !Task.isCancelled {
                await refreshDownstreamHosts()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func savedHostRow(_ host: Host) -> some View {
        if !isPaired(host) {
            Button { showingAdd = true } label: {
                HostPickerRowLabel(host: host, status: "Pair again to connect")
            }
            .buttonStyle(.plain)
        } else if let onSelect {
            Button { onSelect(host) } label: {
                HostPickerRowLabel(host: host, status: status(of: host))
            }
            .buttonStyle(.plain)
        } else {
            // Managing hosts doesn't change what the app shows.
            HostPickerRowLabel(host: host, status: status(of: host))
        }
    }

    private func refreshDownstreamHosts() async {
        await feed?.downstreamConnections.refresh(hosts: downstreamHosts, send: sendDownstream)
    }

    private func sendDownstream(_ hostID: UUID, _ request: WorktreeManagementRequest) async throws -> WorktreeManagementResponse {
        guard let feed, let host = feed.host(id: hostID) else {
            throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
        }
        let isConnect: Bool
        if case .connectRemoteMac = request { isConnect = true } else { isConnect = false }
        return try await RelayedWorktreeManagementClient.send(request, using: feed.provider(for: host, wake: isConnect ? .now : .never))
    }

    private func isPaired(_ host: Host) -> Bool {
        coordinator?.isPaired(host) ?? (host.remoteDeviceID != nil)
    }
}

private struct HostPickerRowLabel: View {
    let host: Host
    let status: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(host.label).font(.body)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
