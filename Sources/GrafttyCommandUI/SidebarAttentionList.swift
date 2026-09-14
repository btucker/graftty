import SwiftUI
import GrafttyProtocol

public struct SidebarAttentionList: View {
    @Bindable public var navigation: SidebarNavigationState
    public var items: [SidebarActivityItem]
    public var projects: [SidebarProject]
    public var icons: [String: Data]
    public var onOpen: (SidebarActivityItem) -> Void
    public init(navigation: SidebarNavigationState, items: [SidebarActivityItem], projects: [SidebarProject],
                icons: [String: Data], onOpen: @escaping (SidebarActivityItem) -> Void) {
        self.navigation = navigation; self.items = items; self.projects = projects; self.icons = icons; self.onOpen = onOpen
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attention").font(.headline).padding(.horizontal, 12)
            TextField("Find a request or project", text: $navigation.query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            Picker("Activity", selection: $navigation.filter) {
                ForEach(SidebarActivityFilter.allCases, id: \.self) { filter in Text(filter.title).tag(filter) }
            }.pickerStyle(.segmented).padding(.horizontal, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let pending = navigation.filter.apply(to: items, query: navigation.query)
                    if pending.isEmpty {
                        Text(navigation.query.isEmpty ? "No \(navigation.filter == .needsYou ? "pending requests" : "activity in this view")." : "No matching requests.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(pending) { item in row(item, recent: false).id(item.id) }
                    if navigation.filter != .running {
                        let activeIDs = Set(items.filter(\.needsAttention).map(\.id) + pending.map(\.id))
                        let projectIDs = Set(projects.map(\.id))
                        let recent = navigation.history.entries.filter {
                            projectIDs.contains($0.item.projectID) && !activeIDs.contains($0.id)
                                && (navigation.query.isEmpty || "\($0.item.projectName) \($0.item.worktreeName) \($0.item.title)".localizedCaseInsensitiveContains(navigation.query))
                        }
                        if !recent.isEmpty {
                            Text("Recently viewed").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                            ForEach(recent) { entry in row(entry.item, recent: true).id("recent:" + entry.id) }
                        }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12).scrollTargetLayout()
            }.scrollPosition(id: Binding(get: { navigation.scrollAnchors["attention"] }, set: { navigation.scrollAnchors["attention"] = $0 }))
        }.padding(.top, 12)
    }
    private func row(_ item: SidebarActivityItem, recent: Bool) -> some View {
        let project = projects.first { $0.id == item.projectID }
        return Button { onOpen(item) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if let project { ProjectIdentityView(project: project, imageData: icons[project.id]) }
                    Text(item.projectName).font(.caption).lineLimit(1)
                    Spacer()
                    if project?.isAvailable == false { Text("Offline").font(.caption2) }
                }
                Text(item.worktreeName).font(.callout).lineLimit(1)
                Text(item.title).font(.caption).foregroundStyle(recent ? Color.secondary : item.needsAttention ? .orange : .green).lineLimit(2)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(recent ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .disabled(project?.isAvailable == false)
            .contextMenu {
                if recent { Button("Remove from Recently Viewed") { navigation.forget(item.id) } }
            }
    }
}
