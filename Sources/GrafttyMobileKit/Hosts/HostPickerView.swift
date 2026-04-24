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
                if store.hosts.isEmpty {
                    Text("No saved hosts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    switch host.transport {
                    case .directHTTP:
                        // NavigationLink(value:) pushes the host onto the
                        // NavigationSplitView detail stack; a plain Button
                        // only mutates state and doesn't navigate on the
                        // iPhone compact layout where the split collapses.
                        NavigationLink(value: host) {
                            hostRow(host)
                        }
                    case .sshTunnel:
                        hostRow(host, detail: "SSH setup saved; tunnel connection is not enabled yet.")
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
    }

    private func hostRow(_ host: Host, detail: String? = nil) -> some View {
        VStack(alignment: .leading) {
            Text(host.label).font(.body)
            Text(host.displayAddress).font(.caption).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
