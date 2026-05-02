#if canImport(UIKit)
import SwiftUI

public struct HostPickerView: View {
    @Bindable var store: HostStore
    @State private var showingAdd = false

    public init(store: HostStore) {
        self.store = store
    }

    public var body: some View {
        List {
            Section("Saved hosts") {
                // Gate empty-state copy on `hasLoaded` — otherwise users
                // with saved hosts see a brief "No saved hosts yet"
                // flicker before the async load lands.
                if store.hasLoaded && store.hosts.isEmpty {
                    Text("No saved hosts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    // NavigationLink(value:) pushes the host onto the
                    // NavigationSplitView detail stack; a plain Button
                    // only mutates state and doesn't navigate on the
                    // iPhone compact layout where the split collapses.
                    NavigationLink(value: host) {
                        VStack(alignment: .leading) {
                            Text(host.label).font(.body)
                            Text(host.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
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
#endif
