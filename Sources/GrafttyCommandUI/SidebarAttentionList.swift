import SwiftUI
import GrafttyProtocol

private struct AttentionPRBadgeAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct AttentionWorktreeNameAnchor: PreferenceKey {
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
    public var expandsAllCards: Bool
    public var compactHeader: Bool
    public var selectionColor: Color
    public var isCurrentWorktree: (SidebarActivityItem) -> Bool
    public init(navigation: SidebarNavigationState, items: [SidebarActivityItem], projects: [SidebarProject],
                selectionColor: Color = .primary.opacity(0.16), compactHeader: Bool = false, expandsAllCards: Bool = false,
                isCurrentWorktree: @escaping (SidebarActivityItem) -> Bool = { _ in true },
                onOpen: @escaping (SidebarActivityItem) async -> Bool) {
        self.expandsAllCards = expandsAllCards
        self.compactHeader = compactHeader
        self.selectionColor = selectionColor; self.isCurrentWorktree = isCurrentWorktree
        self.navigation = navigation; self.items = items; self.projects = projects; self.onOpen = onOpen
    }
    public var body: some View {
        GeometryReader { geometry in
            content(wide: geometry.size.width >= 360)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onChange(of: items, initial: true) { _, current in navigation.updateAttentionItems(current) }
    }

    private func content(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SidebarAttentionHeader(navigation: navigation, compact: compactHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let rows = navigation.attentionItems(live: items, projects: projects)
                    if rows.isEmpty {
                        Text(navigation.query.isEmpty ? "No \(navigation.filter == .needsYou ? "pending requests" : "activity in this view")." : "No matching requests.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(rows) { item in
                        row(item, wide: wide).id(item.id)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12).scrollTargetLayout()
            }.scrollPosition(id: Binding(get: { navigation.scrollAnchors["attention"] }, set: { navigation.scrollAnchors["attention"] = $0 }))
        }.padding(.top, compactHeader ? 0 : 12)
    }

    enum RowStyle: Equatable {
        case expanded, running, other
    }

    private func open(_ item: SidebarActivityItem, navigateToProject: Bool) {
        let visit = navigation.beginOpening(item)
        Task {
            let succeeded = await onOpen(item)
            navigation.finishOpening(visit, succeeded: succeeded, navigateToProject: navigateToProject)
        }
    }

    func rowStyle(for item: SidebarActivityItem) -> RowStyle {
        if item.isBusy { return .running }
        return item.agentStop?.recap != nil || expandsAllCards ? .expanded : .other
    }

    private func row(_ item: SidebarActivityItem, wide: Bool) -> some View {
        let project = projects.first { $0.id == item.projectID }
        let card = SidebarAttentionCardContent(item: item)
        let accent = project.map(ProjectAccentColor.color(for:)) ?? Color.secondary
        let viewed = navigation.hasViewed(item)
        let selected = navigation.selectedAttentionID == item.id && isCurrentWorktree(item)
        let presentation = rowStyle(for: item)
        return Button {
            open(item, navigateToProject: false)
        } label: {
            cardBody(item, card: card, accent: accent, viewed: viewed && !selected,
                     offline: project?.isAvailable != true, wide: wide, style: presentation)
                .padding(presentation == .running ? 9 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? selectionColor : Color.secondary.opacity(viewed ? 0.06 : presentation == .running ? 0.10 : 0.12))
                        .overlay {
                            if presentation != .running {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(accent.opacity(viewed ? 0.05 : presentation == .expanded ? 0.18 : 0.12))
                            }
                        }
                }
        }.buttonStyle(.plain)
            .disabled(project?.isAvailable != true)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(item.isBusy ? "Running" : viewed ? "Viewed" : "")
            .contextMenu {
                Button("Dismiss") { navigation.forget(item.id) }
            }
            .overlayPreferenceValue(AttentionWorktreeNameAnchor.self) { anchor in
                if let anchor {
                    GeometryReader { geometry in
                        let bounds = geometry[anchor]
                        Button { open(item, navigateToProject: true) } label: {
                            Rectangle().fill(.clear).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(project?.isAvailable != true)
                        .help("Open \(card.headerName) worktrees")
                        .accessibilityLabel("Open \(card.headerName) worktrees")
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                    }
                }
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
        case .expanded:
            VStack(alignment: .leading, spacing: 0) {
                cardHeader(item, card: card, accent: accent, offline: offline, wide: wide)
                    .padding(.bottom, 11)
                titleLine(card.title, badge: item.prBadge, font: wide ? .headline : .subheadline, limit: expandsAllCards ? nil : 2)
                    .padding(.bottom, 6)
                if let context = card.sections.first(where: { $0.kind == .context }) {
                    Text(context.text).font(wide ? .callout : .subheadline)
                        .foregroundStyle(Color.primary.opacity(0.8)).lineLimit(expandsAllCards ? nil : 2).help(context.text)
                    if let detail = context.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(expandsAllCards ? nil : 1).help(detail).padding(.top, 4)
                    }
                }
                if let need = card.sections.first(where: { $0.kind == .needsYou }) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("NEEDS YOUR INPUT")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(viewed ? Color.secondary : .orange)
                        Text(need.text).font(.system(size: wide ? 17 : 15, weight: .semibold))
                            .lineLimit(expandsAllCards ? nil : 4).help(need.text)
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
                            .lineLimit(expandsAllCards ? nil : 2).help(next.text)
                    }.padding(.top, 12)
                }
            }
        case .running:
            HStack(alignment: .top, spacing: 9) {
                identity(item.worktreeEmoji, accent: accent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        worktreeName(card.headerName, font: .subheadline)
                        Spacer(minLength: 3)
                        if offline { Text("Offline").font(.caption2) }
                        Text("Running").font(.caption).foregroundStyle(.green)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                            .help("Handed back to the agent").accessibilityLabel("Agent resumed")
                        titleLine(item.agentStop == nil ? item.title : card.title,
                                  badge: item.prBadge, font: .subheadline, limit: 1)
                            .foregroundStyle(.secondary)
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
                worktreeName(card.headerName, font: wide ? .callout : .subheadline)
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

    private func worktreeName(_ name: String, font: Font) -> some View {
        Text(name).font(font).fontWeight(.semibold).lineLimit(1).help(name)
            .anchorPreference(key: AttentionWorktreeNameAnchor.self, value: .bounds) { $0 }
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

    private func titleLine(_ title: String, badge: PRBadge?, font: Font, limit: Int?) -> some View {
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

struct SidebarAttentionHeader: View {
    @Bindable var navigation: SidebarNavigationState
    var compact: Bool
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool

    private var searchIsVisible: Bool { showsSearch || !navigation.query.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if compact {
                HStack {
                    filterPicker.pickerStyle(.menu).tint(.primary)
                    Spacer()
                    Button {
                        if searchIsVisible {
                            navigation.query = ""
                            showsSearch = false
                            searchFocused = false
                        } else {
                            showsSearch = true
                            searchFocused = true
                        }
                    } label: {
                        Image(systemName: searchIsVisible ? "xmark" : "magnifyingglass")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(searchIsVisible ? "Close search" : "Search attention")
                }.padding(.leading, 12).padding(.trailing, 4)
                if searchIsVisible { searchField }
            } else {
                Text("Attention").font(.headline).padding(.horizontal, 12)
                searchField
                ViewThatFits(in: .horizontal) {
                    filterPicker.pickerStyle(.segmented).fixedSize()
                    filterPicker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 10)
            }
        }
    }

    private var searchField: some View {
        TextField("Find a request or project", text: $navigation.query)
            .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            .focused($searchFocused)
    }

    private var filterPicker: some View {
        Picker("Filter attention", selection: $navigation.filter) {
            ForEach(SidebarActivityFilter.allCases, id: \.self) { filter in Text(filter.title).tag(filter) }
        }.labelsHidden().fixedSize(horizontal: false, vertical: true)
    }
}
