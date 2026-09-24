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
    public var onOpen: (SidebarActivityItem) async -> Bool
    public var selectionColor: Color
    public var isCurrentWorktree: (SidebarActivityItem) -> Bool
    public init(navigation: SidebarNavigationState, items: [SidebarActivityItem], projects: [SidebarProject],
                selectionColor: Color = .primary.opacity(0.16),
                isCurrentWorktree: @escaping (SidebarActivityItem) -> Bool = { _ in true },
                onOpen: @escaping (SidebarActivityItem) async -> Bool) {
        self.selectionColor = selectionColor; self.isCurrentWorktree = isCurrentWorktree
        self.navigation = navigation; self.items = items; self.projects = projects; self.onOpen = onOpen
    }
    public var body: some View {
        GeometryReader { geometry in
            content(wide: geometry.size.width >= 360)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func content(wide: Bool) -> some View {
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
                        let allExcluded = !projects.isEmpty && projects.allSatisfy { navigation.excludedAttentionProjectIDs.contains($0.id) }
                        Text(allExcluded ? "Select a project to see its attention." : navigation.query.isEmpty ? "No \(navigation.filter == .needsYou ? "pending requests" : "activity in this view")." : "No matching requests.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(rows) { item in row(item, wide: wide).id(item.id) }
                }.padding(.horizontal, 10).padding(.bottom, 12).scrollTargetLayout()
            }.scrollPosition(id: Binding(get: { navigation.scrollAnchors["attention"] }, set: { navigation.scrollAnchors["attention"] = $0 }))
        }.padding(.top, 12)
    }
    private var filterPicker: some View {
        Picker("Filter attention", selection: $navigation.filter) {
            ForEach(SidebarActivityFilter.allCases, id: \.self) { filter in Text(filter.title).tag(filter) }
        }.labelsHidden().fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: SidebarActivityItem, wide: Bool) -> some View {
        let project = projects.first { $0.id == item.projectID }
        let card = SidebarAttentionCardContent(item: item)
        let accent = project.map(ProjectAccentColor.color(for:)) ?? Color.secondary
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
                HStack(alignment: .top, spacing: 7) {
                    Group {
                        if let emoji = item.worktreeEmoji {
                            Text(emoji).font(.system(size: 23))
                        } else {
                            Image(systemName: "square.dashed")
                                .font(.system(size: 18)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.headerName).font(wide ? .callout : .subheadline).fontWeight(.semibold)
                            .lineLimit(1).help(card.headerName)
                        if let paneTitle = card.paneTitle {
                            Text(paneTitle).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).help(paneTitle)
                        }
                    }
                    Spacer(minLength: 4)
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
                    Text(card.title)
                        .font(wide ? .headline : .subheadline)
                        .fontWeight(item.agentStop?.recap == nil && item.agentStop?.paneTitle == nil ? .regular : .semibold)
                        .lineLimit(2)
                }
                if !card.sections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(card.sections) { section in
                            recapSection(section, viewed: viewed, wide: wide)
                        }
                    }
                } else if item.agentStop == nil {
                    Text(item.title).font(.caption).foregroundStyle(viewed ? Color.secondary : item.needsAttention ? .orange : .green).lineLimit(2)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? selectionColor : Color.secondary.opacity(viewed ? 0.06 : 0.12))
                        .overlay(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(viewed ? 0.05 : 0.13)))
                }
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

    private func recapSection(_ section: SidebarAttentionCardContent.Section, viewed: Bool, wide: Bool) -> some View {
        let color: Color = switch section.kind {
        case .context: .secondary
        case .needsYou: viewed ? .secondary : .orange
        case .upNext: .teal
        }
        let label: String = switch section.kind {
        case .context: "CONTEXT"
        case .needsYou: "NEEDS YOU"
        case .upNext: "UP NEXT"
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: wide ? 11 : 10, weight: .bold)).tracking(1)
                .foregroundStyle(color)
            Text(section.text).font(wide ? .body : .callout)
                .fontWeight(section.kind == .needsYou ? .semibold : .regular)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = section.detail {
                Text(detail).font(wide ? .callout : .subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
