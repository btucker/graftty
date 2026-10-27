import GrafttyProtocol
import SwiftUI

/// A pinned brief above an independently scrolling, bottom-anchored timeline.
public struct WorktreeContextPanel: View {
    public let context: SidebarWorktreeContext
    private let foreground: Color
    private let secondary: Color
    private let onClose: () -> Void
    @State private var follow: TimelineFollow

    private static let latestID = "worktree.context.timeline.latest"

    public init(context: SidebarWorktreeContext, foreground: Color = .primary,
                secondary: Color = .secondary, collapsesBrief: Bool = false, onClose: @escaping () -> Void) {
        self.context = context
        self.foreground = foreground
        self.secondary = secondary
        self.onClose = onClose
        _follow = State(initialValue: TimelineFollow(collapsesBrief: collapsesBrief))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    pinnedBrief(cap: geometry.size.height / 2)
                    Divider()
                    timeline(panelHeight: geometry.size.height)
                }
            }
        }
        .foregroundStyle(foreground)
        .onChange(of: context.item.worktreeIdentity) { _, _ in
            follow = TimelineFollow(collapsesBrief: follow.collapsesBrief)
        }
    }

    private var header: some View {
        HStack {
            Label("Context", systemImage: "text.alignleft")
                .font(.callout).fontWeight(.medium)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close context")
            .accessibilityIdentifier("worktree.context.close")
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }

    @ViewBuilder private func pinnedBrief(cap: CGFloat) -> some View {
        if follow.showsCollapsedBrief {
            collapsedBrief
        } else {
            let brief = WorktreeBriefContent(context: context, foreground: foreground, secondary: secondary,
                includesHistory: false)
                .padding(.horizontal, 24).padding(.vertical, 20)
            // The brief scrolls on its own only when it is taller than its cap.
            ViewThatFits(in: .vertical) {
                brief
                ScrollView { brief }
            }
            .frame(maxHeight: max(0, cap))
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

    private func timeline(panelHeight: CGFloat) -> some View {
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
            .modifier(TimelineFollowTracking(follow: $follow, panelHeight: panelHeight))
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

/// Opens the timeline at its latest event and reports whether the reader is at its bottom.
private struct TimelineFollowTracking: ViewModifier {
    @Binding var follow: TimelineFollow
    /// The brief and timeline together; the brief's cap is half of it.
    let panelHeight: CGFloat

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
                    next.scrolled(distanceFromBottom: distance, panelHeight: panelHeight)
                    if next != follow { follow = next }
                }
        } else {
            // Without scroll geometry the timeline stays at the bottom anchor and
            // `follow` keeps its initial at-bottom state, so nothing extra shows.
            content.defaultScrollAnchor(.bottom)
        }
    }
}
