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
                    let buckets = SidebarAttentionBuckets(items: rows)
                    if rows.isEmpty {
                        Text(navigation.query.isEmpty ? "No \(navigation.filter == .needsYou ? "pending requests" : "activity in this view")." : "No matching requests.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                    if navigation.filter == .needsYou {
                        if !buckets.questions.isEmpty {
                            sectionHeader("Questions", count: buckets.questions.count, color: .orange)
                            ForEach(Array(buckets.questions.enumerated()), id: \.element.id) { index, item in
                                row(item, wide: wide, style: index == 0 ? .featuredQuestion : .question).id(item.id)
                            }
                        }
                        if !buckets.stopped.isEmpty {
                            sectionHeader("Stopped agents", count: buckets.stopped.count, color: .secondary)
                                .padding(.top, buckets.questions.isEmpty ? 0 : 8)
                            ForEach(buckets.stopped) { item in row(item, wide: wide, style: .stopped).id(item.id) }
                        }
                        if !buckets.other.isEmpty {
                            sectionHeader("Other requests", count: buckets.other.count, color: .secondary)
                                .padding(.top, buckets.questions.isEmpty && buckets.stopped.isEmpty ? 0 : 8)
                            ForEach(buckets.other) { item in row(item, wide: wide, style: .other).id(item.id) }
                        }
                    } else {
                        ForEach(rows) { item in
                            let style: RowStyle = item.agentStop?.recap?.need != nil ? .question : item.agentStop != nil ? .stopped : .other
                            row(item, wide: wide, style: style).id(item.id)
                        }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12).scrollTargetLayout()
            }.scrollPosition(id: Binding(get: { navigation.scrollAnchors["attention"] }, set: { navigation.scrollAnchors["attention"] = $0 }))
        }.padding(.top, 12)
    }

    private var filterPicker: some View {
        Picker("Filter attention", selection: $navigation.filter) {
            ForEach(SidebarActivityFilter.allCases, id: \.self) { filter in Text(filter.title).tag(filter) }
        }.labelsHidden().fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.semibold)
            Text(count.formatted()).foregroundStyle(color)
        }
        .font(.caption)
        .padding(.horizontal, 3)
        .padding(.top, 4)
    }

    private enum RowStyle {
        case featuredQuestion, question, stopped, other
    }

    private func row(_ item: SidebarActivityItem, wide: Bool, style: RowStyle) -> some View {
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
            cardBody(item, card: card, accent: accent, viewed: viewed,
                     offline: project?.isAvailable == false, wide: wide, style: style)
                .padding(style == .stopped ? 9 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? selectionColor : Color.secondary.opacity(viewed ? 0.06 : style == .stopped ? 0.10 : 0.12))
                        .overlay {
                            if style != .stopped {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(accent.opacity(viewed ? 0.05 : style == .featuredQuestion ? 0.18 : 0.12))
                            }
                        }
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

    @ViewBuilder
    private func cardBody(_ item: SidebarActivityItem, card: SidebarAttentionCardContent,
                          accent: Color, viewed: Bool, offline: Bool, wide: Bool,
                          style: RowStyle) -> some View {
        switch style {
        case .featuredQuestion:
            VStack(alignment: .leading, spacing: 0) {
                cardHeader(item, card: card, accent: accent, offline: offline, wide: wide)
                    .padding(.bottom, 11)
                titleLine(card.title, badge: item.prBadge, font: wide ? .headline : .subheadline, limit: 2)
                    .padding(.bottom, 6)
                if let context = card.sections.first(where: { $0.kind == .context }) {
                    Text(context.text).font(wide ? .callout : .subheadline)
                        .foregroundStyle(Color.primary.opacity(0.8)).lineLimit(2).help(context.text)
                    if let detail = context.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(detail).padding(.top, 4)
                    }
                }
                if let need = card.sections.first(where: { $0.kind == .needsYou }) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("NEEDS YOUR INPUT")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(viewed ? Color.secondary : .orange)
                        Text(need.text).font(.system(size: wide ? 17 : 15, weight: .semibold))
                            .lineLimit(4).help(need.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.top, 14)
                }
                if let next = card.sections.first(where: { $0.kind == .upNext }) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("NEXT").font(.system(size: 10, weight: .bold)).tracking(0.8)
                            .foregroundStyle(.teal)
                        Text(next.text).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).help(next.text)
                    }.padding(.top, 12)
                }
            }
        case .question:
            VStack(alignment: .leading, spacing: 9) {
                cardHeader(item, card: card, accent: accent, offline: offline, wide: wide)
                titleLine(card.title, badge: item.prBadge, font: .subheadline, limit: 1)
                    .foregroundStyle(.secondary)
                if let need = card.sections.first(where: { $0.kind == .needsYou }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NEEDS YOU").font(.system(size: 10, weight: .bold)).tracking(0.8)
                            .foregroundStyle(viewed ? Color.secondary : .orange)
                        Text(need.text).font(.system(size: wide ? 15 : 14, weight: .semibold))
                            .lineLimit(wide ? 3 : 4).help(need.text)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .stopped:
            HStack(alignment: .top, spacing: 9) {
                identity(item.worktreeEmoji, accent: accent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(card.headerName).font(.subheadline).fontWeight(.semibold)
                            .lineLimit(1).help(card.headerName)
                        Spacer(minLength: 3)
                        if offline { Text("Offline").font(.caption2) }
                        elapsedTime(item)
                    }
                    if let paneTitle = card.paneTitle {
                        Text(paneTitle).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).help(paneTitle)
                    }
                    titleLine(card.title, badge: item.prBadge, font: .subheadline, limit: 1)
                    if let next = card.sections.first(where: { $0.kind == .upNext }) {
                        Text(next.text).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(next.text)
                    }
                }
            }
        case .other:
            VStack(alignment: .leading, spacing: 7) {
                cardHeader(item, card: card, accent: accent, offline: offline, wide: wide)
                titleLine(item.title, badge: item.prBadge, font: .subheadline, limit: 2)
                    .foregroundStyle(viewed ? Color.secondary : item.needsAttention ? .orange : .green)
            }
        }
    }

    private func cardHeader(_ item: SidebarActivityItem, card: SidebarAttentionCardContent,
                            accent: Color, offline: Bool, wide: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            identity(item.worktreeEmoji, accent: accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.headerName).font(wide ? .callout : .subheadline).fontWeight(.semibold)
                    .lineLimit(1).help(card.headerName)
                if let paneTitle = card.paneTitle {
                    Text(paneTitle).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).help(paneTitle)
                }
            }
            Spacer(minLength: 4)
            if offline { Text("Offline").font(.caption2) }
            elapsedTime(item)
        }
    }

    private func identity(_ emoji: String?, accent: Color) -> some View {
        Group {
            if let emoji {
                Text(emoji).font(.system(size: 23))
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: 18)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 34, height: 34)
        .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func elapsedTime(_ item: SidebarActivityItem) -> some View {
        if let stop = item.agentStop {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(stop.elapsedDescription(at: context.date))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func titleLine(_ title: String, badge: PRBadge?, font: Font, limit: Int) -> some View {
        HStack(spacing: 6) {
            if let badge {
                // The browser link is a sibling overlay, not a nested button.
                Text(verbatim: badge.referenceText).font(.caption).fontWeight(.medium)
                    .padding(.horizontal, 3).fixedSize().hidden().accessibilityHidden(true)
                    .anchorPreference(key: AttentionPRBadgeAnchor.self, value: .bounds) { $0 }
            }
            Text(title).font(font).fontWeight(.semibold).lineLimit(limit).help(title)
        }
    }
}
