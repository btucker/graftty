#if canImport(UIKit)
import SwiftUI

public struct HostPickerView: View {
    @Bindable var store: HostStore
    @State private var showingAdd = false

    /// When non-nil, tapping a saved-host row fires this callback instead of
    /// using `NavigationLink(value: host)`. Lets the iPad host-switcher
    /// popover reuse this view body without a navigation push.
    public let onSelect: ((Host) -> Void)?

    public init(store: HostStore, onSelect: ((Host) -> Void)? = nil) {
        self.store = store
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            Section("Saved hosts") {
                if store.hasLoaded && store.hosts.isEmpty {
                    Text("No saved hosts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    if let onSelect {
                        Button {
                            onSelect(host)
                        } label: {
                            HostPickerRowLabel(host: host)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: host) {
                            HostPickerRowLabel(host: host)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        try? store.delete(store.hosts[i].id)
                    }
                }
            }
        }
        .navigationTitle("Graftty")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddHostView { host in try store.add(host) }
        }
        .task { await store.loadIfNeeded() }
    }
}

private struct HostPickerRowLabel: View {
    let host: Host

    var body: some View {
        VStack(alignment: .leading) {
            Text(host.label).font(.body)
            Text(host.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
