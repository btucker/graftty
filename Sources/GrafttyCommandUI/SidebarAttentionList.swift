import SwiftUI
import GrafttyProtocol

private struct AttentionPRBadgeAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

public struct SidebarAttentionList: View {
    @Bindable public var navigation: SidebarNavigationState
    public var items: [SidebarActivityItem]
    public var projects: [SidebarProject]
    public var icons: [String: Data]
    public var onOpen: (SidebarActivityItem) async -> Bool
    public var selectionColor: Color
    public var isCurrentWorktree: (SidebarActivityItem) -> Bool
    public init(navigation: SidebarNavigationState, items: [SidebarActivityItem], projects: [SidebarProject],
                icons: [String: Data], selectionColor: Color = .primary.opacity(0.16),
                isCurrentWorktree: @escaping (SidebarActivityItem) -> Bool = { _ in true },
                onOpen: @escaping (SidebarActivityItem) async -> Bool) {
        self.selectionColor = selectionColor; self.isCurrentWorktree = isCurrentWorktree
        self.navigation = navigation; self.items = items; self.projects = projects; self.icons = icons; self.onOpen = onOpen
    }
    public var body: some View {
        GeometryReader { geometry in
            content.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attention").font(.headline).padding(.horizontal, 12)
            TextField("Find a request or project", text: $navigation.query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            ViewThatFits(in: .horizontal) {
                filterPicker.pickerStyle(.segmented).fixedSize()
                filterPicker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let rows = navigation.attentionItems(live: items, projects: projects)
                    if rows.isEmpty {
                        Text(navigation.query.isEmpty ? "No \(navigation.filter == .needsYou ? "pending requests" : "activity in this view")." : "No matching requests.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(rows) { item in row(item).id(item.id) }
                }.padding(.horizontal, 10).padding(.bottom, 12).scrollTargetLayout()
            }.scrollPosition(id: Binding(get: { navigation.scrollAnchors["attention"] }, set: { navigation.scrollAnchors["attention"] = $0 }))
        }.padding(.top, 12)
    }
    private var filterPicker: some View {
        Picker("Filter attention", selection: $navigation.filter) {
            ForEach(SidebarActivityFilter.allCases, id: \.self) { filter in Text(filter.title).tag(filter) }
        }.labelsHidden().fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: SidebarActivityItem) -> some View {
        let project = projects.first { $0.id == item.projectID }
        let viewed = navigation.hasViewed(item)
        let selected = navigation.selectedAttentionID == item.id && isCurrentWorktree(item)
        return Button {
            let visit = navigation.beginOpening(item)
            Task {
                let succeeded = await onOpen(item)
                navigation.finishOpening(visit, succeeded: succeeded)
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if let project { ProjectIdentityView(project: project, imageData: icons[project.id]) }
                    Text(item.projectName).font(.caption).lineLimit(1)
                    Spacer()
                    if project?.isAvailable == false { Text("Offline").font(.caption2) }
                    if let stop = item.agentStop {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(stop.elapsedDescription(at: context.date))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    if let badge = item.prBadge {
                        // Reserve the badge's space inside the card button. Its
                        // browser action is a sibling overlay, not a nested button.
                        Text(verbatim: badge.referenceText).font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 3).fixedSize().hidden().accessibilityHidden(true)
                            .anchorPreference(key: AttentionPRBadgeAnchor.self, value: .bounds) { $0 }
                    }
                    Text(item.agentStop?.recap?.title ?? item.agentStop?.paneTitle ?? item.worktreeName)
                        .font(.callout)
                        .fontWeight(item.agentStop?.recap == nil && item.agentStop?.paneTitle == nil ? .regular : .semibold)
                        .lineLimit(2)
                }
                if let recap = item.agentStop?.recap {
                    if let paneTitle = item.agentStop?.paneTitle, paneTitle != recap.title {
                        Text(paneTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("Done: " + recap.completed).font(.caption).lineLimit(2)
                    Text("Next: " + recap.next).font(.caption).lineLimit(2)
                    if let need = recap.need {
                        Text("Need: " + need).font(.caption)
                            .foregroundStyle(viewed ? Color.secondary : .orange).lineLimit(2)
                    }
                } else {
                    Text(item.title).font(.caption).foregroundStyle(viewed ? Color.secondary : item.needsAttention ? .orange : .green).lineLimit(2)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(selected ? selectionColor : Color.secondary.opacity(viewed ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .disabled(project?.isAvailable == false)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(viewed ? "Viewed" : "")
            .contextMenu {
                if viewed { Button("Remove from History") { navigation.forget(item.id) } }
            }
            .overlayPreferenceValue(AttentionPRBadgeAnchor.self) { anchor in
                if let anchor, let badge = item.prBadge {
                    GeometryReader { geometry in
                        let bounds = geometry[anchor]
                        SidebarPRBadge(badge: badge)
                            .frame(width: bounds.width, height: bounds.height)
                            .position(x: bounds.midX, y: bounds.midY)
                    }
                }
            }
    }
}
