#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

public struct SessionPickerView: View {
    @Bindable var controller: HostController
    public let onSelect: (SessionInfo) -> Void

    public init(controller: HostController, onSelect: @escaping (SessionInfo) -> Void) {
        self.controller = controller
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            ForEach(grouped, id: \.0) { repo, items in
                Section(repo) {
                    ForEach(items, id: \.name) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.worktreeDisplayName).font(.body)
                                Text(item.worktreePath).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(controller.host.label)
        .refreshable { await controller.refreshSessions() }
        .task { await controller.refreshSessions() }
    }

    private var grouped: [(String, [SessionInfo])] {
        Dictionary(grouping: controller.sessions, by: \.repoDisplayName)
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }
}
#endif
