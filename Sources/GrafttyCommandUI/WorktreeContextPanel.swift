import GrafttyProtocol
import SwiftUI

/// The worktree's title pinned above one bottom-anchored scroll: optional
/// details, the timeline, where things stand, any waiting question, and status.
public struct WorktreeContextPanel: View {
    public let context: SidebarWorktreeContext
    private let theme: GhosttyThemeColors
    private let foreground: Color
    private let secondary: Color
    private let onClose: () -> Void
    private let showAgent: ((String) -> Void)?
    private let readTranscript: (@MainActor (String) async -> String?)?
    @State private var archivedTranscript: String?
    @State private var follow = TimelineFollow()
    @State private var showsDetails = false

    private static let latestID = "worktree.context.timeline.latest"
    private static let detailsID = "worktree.context.details.top"
    private let hostLabel: String?

    public init(context: SidebarWorktreeContext, theme: GhosttyThemeColors = .fallback, hostLabel: String? = nil, foreground: Color? = nil,
                secondary: Color? = nil,
                readTranscript: (@MainActor (String) async -> String?)? = nil, showAgent: ((String) -> Void)? = nil, onClose: @escaping () -> Void) {
        self.context = context
        self.theme = theme
        self.hostLabel = hostLabel
        self.foreground = foreground ?? theme.foreground
        self.secondary = secondary ?? theme.foreground.opacity(0.68)
        self.onClose = onClose
        self.readTranscript = readTranscript
        self.showAgent = showAgent
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            theme.contextSeparator.frame(height: 1)
            scroll
        }
        .foregroundStyle(foreground)
        .background(theme.contextBackground)
        .overlay(alignment: .leading) {
            theme.contextSeparator.frame(width: 1).allowsHitTesting(false)
        }
        .sheet(isPresented: Binding(get: { archivedTranscript != nil }, set: { if !$0 { archivedTranscript = nil } })) {
            VStack(spacing: 0) {
                HStack { Text("Agent transcript").font(.headline); Spacer(); Button("Done") { archivedTranscript = nil } }.padding()
                Divider()
                ScrollView { Text(archivedTranscript ?? "").font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            }.frame(minWidth: 320, idealWidth: 720, minHeight: 320, idealHeight: 600)
        }
        .onChange(of: context.item.worktreeIdentity) { _, _ in
            follow = TimelineFollow()
            showsDetails = false
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                showsDetails.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.headerTitle(for: context)).font(.headline).lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsDetails ? "Hides the purpose and decisions" : "Shows the purpose and decisions")
            .accessibilityIdentifier("worktree.context.title")
            if let hostLabel {
                Text(hostLabel).font(.callout).foregroundStyle(secondary).lineLimit(1)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close context")
            .accessibilityIdentifier("worktree.context.close")
        }
        .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 3)
    }

    private var scroll: some View {
        let timeline = WorktreeTimeline(context)
        let sections = Self.sections(for: context, showsDetails: showsDetails, timeline: timeline)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(sections, id: \.self) { section in
                        switch section {
                        case .details:
                            WorktreeContextDetails(context: context, secondary: secondary) { completedAgents }
                                .id(Self.detailsID)
                        case .timeline:
                            WorktreeContextHistory(context: context, timeline: timeline, secondary: secondary)
                        case .now:
                            if let brief = context.brief {
                                VStack(alignment: .leading, spacing: 20) {
                                    theme.contextSeparator.frame(height: 1)
                                    WorktreeContextNow(brief: brief, secondary: secondary)
                                }
                            }
                        case .empty:
                            WorktreeContextEmpty(context: context, secondary: secondary)
                        case .ask:
                            WorktreeContextAsk(context: context, secondary: secondary)
                        case .status:
                            WorktreeContextStatus(context: context, secondary: secondary)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                // After the padding, so scrolling to it reaches the true end rather than the at-bottom tolerance edge.
                Color.clear.frame(height: 1).id(Self.latestID)
            }
            .modifier(TimelineFollowTracking(follow: $follow))
            .onChange(of: FollowKey(context: context, lastEvent: timeline.events.last?.id)) { _, _ in
                if follow.receivedEvent() { proxy.scrollTo(Self.latestID, anchor: .bottom) }
            }
            // The scroll opens at its end, but details appear at its top. Scroll once
            // they are laid out; in this update they do not exist yet.
            .onChange(of: showsDetails) { _, shows in
                if shows { Task { @MainActor in proxy.scrollTo(Self.detailsID, anchor: .top) } }
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
        // Another worktree gets a fresh scroll view, so it opens at its own latest content.
        .id(context.item.worktreeIdentity)
    }

    /// Anything that changes the end of the scroll: a new event, a new brief, or a new question.
    private struct FollowKey: Equatable {
        let lastEvent: String?
        let updatedAt: Double?
        let question: String?
        init(context: SidebarWorktreeContext, lastEvent: String?) {
            self.lastEvent = lastEvent
            updatedAt = context.brief?.updatedAt
            question = context.question
        }
    }

    @ViewBuilder private var completedAgents: some View {
        if let agents = context.worktree.agents?.filter({ ($0.resultCount ?? 0) > 0 || $0.result != nil || !($0.previousResults ?? []).isEmpty }), !agents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Completed agents · \(agents.count)").font(.caption).fontWeight(.medium).foregroundStyle(secondary)
                ForEach(agents) { agent in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            AgentProviderIcon(provider: agent.provider)
                            Text(agent.name).fontWeight(.medium)
                            Spacer()
                            Text(agent.status == "closed" ? "Closed" : agent.status == "awaiting-cleanup" ? "Awaiting cleanup" : agent.status.capitalized).foregroundStyle(secondary)
                        }
                        if agent.resultsAreSummaries == true {
                            Text("Result previews · \(agent.resultCount ?? 0) retained assignments").foregroundStyle(secondary)
                        }
                        if let showAgent { Button("Open agent tab") { showAgent(agent.id) } }
                        if let result = agent.result { Text(result).textSelection(.enabled) }
                        if let readTranscript, agent.status == "closed" {
                            Button("Read transcript") {
                                Task { archivedTranscript = await readTranscript(agent.id) ?? "No transcript was available when this session closed." }
                            }
                        }
                        if let previous = agent.previousResults, !previous.isEmpty {
                            DisclosureGroup("Previous assignments") {
                                ForEach(Array(previous.enumerated()), id: \.offset) { _, result in
                                    Text(result).textSelection(.enabled).padding(.vertical, 4)
                                }
                            }
                        }
                    }.font(.caption)
                }
            }
        }
    }
}

/// Opens the timeline at its latest event and reports whether the reader is at its bottom.
private struct TimelineFollowTracking: ViewModifier {
    @Binding var follow: TimelineFollow

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
                    next.scrolled(distanceFromBottom: distance)
                    if next != follow { follow = next }
                }
        } else {
            // Without scroll geometry the timeline stays at the bottom anchor and
            // `follow` keeps its initial at-bottom state, so nothing extra shows.
            content.defaultScrollAnchor(.bottom)
        }
    }
}
