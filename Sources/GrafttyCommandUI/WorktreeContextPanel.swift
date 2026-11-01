import GrafttyProtocol
import SwiftUI

/// A pinned brief above an independently scrolling, bottom-anchored timeline.
public struct WorktreeContextPanel: View {
    public let context: SidebarWorktreeContext
    private let theme: GhosttyThemeColors
    private let foreground: Color
    private let secondary: Color
    private let onClose: () -> Void
    @State private var follow: TimelineFollow
    @State private var requestedBriefHeight: CGFloat?
    @State private var renderedBriefHeight: CGFloat = 0
    @State private var dragStartBriefHeight: CGFloat?

    private static let latestID = "worktree.context.timeline.latest"

    public init(context: SidebarWorktreeContext, theme: GhosttyThemeColors = .fallback, foreground: Color? = nil,
                secondary: Color? = nil, collapsesBrief: Bool = false, onClose: @escaping () -> Void) {
        self.context = context
        self.theme = theme
        self.foreground = foreground ?? theme.foreground
        self.secondary = secondary ?? theme.foreground.opacity(0.68)
        self.onClose = onClose
        _follow = State(initialValue: TimelineFollow(collapsesBrief: collapsesBrief))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            theme.contextSeparator.frame(height: 1)
            GeometryReader { geometry in
                let limit = max(0, geometry.size.height - HorizontalResizeDivider.thickness - 96)
                let chosenHeight = requestedBriefHeight.map { min(limit, max(min(96, limit), $0)) }
                let cap = chosenHeight ?? min(geometry.size.height / 2, limit)
                VStack(spacing: 0) {
                    pinnedBrief(cap: cap)
                        .frame(height: follow.showsCollapsedBrief ? nil : chosenHeight, alignment: .top)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { renderedBriefHeight = $0 }
                    HorizontalResizeDivider(label: "Resize context summary", onResize: { translation in
                        if dragStartBriefHeight == nil { dragStartBriefHeight = renderedBriefHeight }
                        follow.expandBrief()
                        requestedBriefHeight = min(limit, max(min(96, limit), (dragStartBriefHeight ?? renderedBriefHeight) + translation))
                    }, onResizeEnd: { dragStartBriefHeight = nil })
                    timeline(panelHeight: geometry.size.height, briefHeight: cap)
                }
            }
        }
        .foregroundStyle(foreground)
        .background(theme.contextBackground)
        .overlay(alignment: .leading) {
            theme.contextSeparator.frame(width: 1).allowsHitTesting(false)
        }
        .onChange(of: context.item.worktreeIdentity) { _, _ in
            follow = TimelineFollow(collapsesBrief: follow.collapsesBrief)
            requestedBriefHeight = nil
            dragStartBriefHeight = nil
        }
    }

    private var header: some View {
        HStack {
            Label("Context", systemImage: "sidebar.right")
                .font(.callout).fontWeight(.semibold)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close context")
            .accessibilityIdentifier("worktree.context.close")
        }.padding(.horizontal, 20).padding(.vertical, 3)
    }

    @ViewBuilder private func pinnedBrief(cap: CGFloat) -> some View {
        if follow.showsCollapsedBrief {
            collapsedBrief
        } else {
            let brief = WorktreeBriefContent(context: context, foreground: foreground, secondary: secondary,
                includesHistory: false)
                .padding(.horizontal, 24).padding(.vertical, 20)
                .fixedSize(horizontal: false, vertical: true)
            // The brief scrolls on its own only when it is taller than its cap.
            CappedBriefLayout(maxHeight: max(0, cap)) {
                ViewThatFits(in: .vertical) {
                    brief
                    ScrollView { brief }
                }
            }
            .accessibilityIdentifier("worktree.context.brief")
        }
    }

    private var collapsedBrief: some View {
        let summary = TimelineFollow.collapsedSummary(title: context.brief?.title ?? context.worktree.displayName,
            next: context.brief?.next, question: context.question)
        return Button {
            follow.expandBrief()
        } label: {
            HStack(spacing: 8) {
                Text(summary.title).fontWeight(.semibold).layoutPriority(1)
                if let detail = summary.detail {
                    Text(detail).foregroundStyle(summary.isQuestion ? AnyShapeStyle(.orange) : AnyShapeStyle(secondary))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(secondary)
            }
            .font(.callout)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([summary.title, summary.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows the full brief")
        .accessibilityIdentifier("worktree.context.brief.collapsed")
    }

    private func timeline(panelHeight: CGFloat, briefHeight: CGFloat) -> some View {
        let timeline = WorktreeTimeline(context)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if !timeline.events.isEmpty {
                        WorktreeContextHistory(context: context, timeline: timeline, secondary: secondary)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(foreground)
                            .textSelection(.enabled)
                    }
                    // After the padding, so scrolling to it reaches the true end rather than the at-bottom tolerance edge.
                    Color.clear.frame(height: 1).id(Self.latestID)
                }
            }
            .modifier(TimelineFollowTracking(follow: $follow, panelHeight: panelHeight, briefHeight: briefHeight))
            .onChange(of: timeline.events.last?.id) { _, _ in
                if follow.receivedEvent() { proxy.scrollTo(Self.latestID, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if follow.showsJumpToLatest {
                    Button {
                        follow.jumpToLatest()
                        proxy.scrollTo(Self.latestID, anchor: .bottom)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(Color.accentColor))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("worktree.context.jumpToLatest")
                }
            }
        }
        // Another worktree gets a fresh scroll view, so it opens at its own latest event.
        .id(context.item.worktreeIdentity)
    }
}

/// Measures before placement so the timeline opens with its final viewport height.
private struct CappedBriefLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width,
            height: min(ideal.height, maxHeight, proposal.height ?? maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
            proposal: .init(width: bounds.width, height: bounds.height))
    }
}

/// Opens the timeline at its latest event and reports whether the reader is at its bottom.
private struct TimelineFollowTracking: ViewModifier {
    @Binding var follow: TimelineFollow
    let panelHeight: CGFloat
    let briefHeight: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    TimelineFollow.distanceFromBottom(contentHeight: geometry.contentSize.height,
                        offsetY: geometry.contentOffset.y,
                        visibleHeight: geometry.containerSize.height - geometry.contentInsets.bottom)
                } action: { _, distance in
                    // The distance changes every scrolled point; write only when the follow state changes.
                    var next = follow
                    next.scrolled(distanceFromBottom: distance, panelHeight: panelHeight, briefHeight: briefHeight)
                    if next != follow { follow = next }
                }
        } else {
            // Without scroll geometry the timeline stays at the bottom anchor and
            // `follow` keeps its initial at-bottom state, so nothing extra shows.
            content.defaultScrollAnchor(.bottom)
        }
    }
}
