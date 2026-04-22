#if canImport(UIKit)
import SwiftUI

public struct HostPickerView: View {
    @Bindable var store: HostStore
    @State private var showingAdd = false
    public let onSelect: (Host) -> Void

    public init(store: HostStore, onSelect: @escaping (Host) -> Void) {
        self.store = store
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            Section("Saved hosts") {
                if store.hosts.isEmpty {
                    Text("No saved hosts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.hosts) { host in
                    Button {
                        onSelect(host)
                    } label: {
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
    }
}
#endif
