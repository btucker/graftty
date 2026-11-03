#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol

public struct HostPickerView: View {
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
        if feed.state.isLive(host.id) { return "Connected" }
        return feed.state.isAsleep(host.id) ? "Asleep" : "Not connected"
    }

    public var body: some View {
        List {
            if let feed { DownstreamHostsSection(feed: feed) }
            Section("Paired Macs") {
                if store.hasLoaded && store.hosts.isEmpty {
                    Text("No paired Macs yet.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    if !isPaired(host) {
                        Button {
                            showingAdd = true
                        } label: {
                            HostPickerRowLabel(
                                host: host,
                                status: "Pair again to connect"
                            )
                        }
                        .buttonStyle(.plain)
                    } else if let onSelect {
                        Button {
                            onSelect(host)
                        } label: {
                            HostPickerRowLabel(host: host, status: status(of: host))
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Managing hosts doesn't change what the app shows.
                        HostPickerRowLabel(host: host, status: status(of: host))
                    }
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
        .task { await store.loadIfNeeded() }
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
