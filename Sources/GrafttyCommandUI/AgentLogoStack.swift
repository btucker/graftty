import SwiftUI
import GrafttyProtocol

/// One agent as the sidebar's logo stack shows it.
public struct AgentLogo: Identifiable, Equatable, Sendable {
    /// The agent's id, which selects it.
    public let id: String
    /// The agent's terminal session, for clients that select by pane.
    public let session: String
    public let provider: String?
    /// The agent's terminal title, shown when the pointer rests on its logo.
    public let title: String
    public let status: AgentTileStatus

    public init(id: String, session: String, provider: String?, title: String, status: AgentTileStatus) {
        self.id = id; self.session = session; self.provider = provider; self.title = title; self.status = status
    }

    /// Every agent in the worktree with a terminal or retained result, in start order.
    public static func logos(in context: SidebarWorktreeContext, isCached: Bool) -> [AgentLogo] {
        let leaves = context.worktree.layout?.leaves ?? []
        return (context.worktree.agents ?? []).compactMap { agent in
            guard let session = agent.presentationSessionName else { return nil }
            let leaf = leaves.first { $0.sessionName == session }
            let needsInput = context.needsInput(session: session)
            // An unread stop outranks the stopped agent's own lagging liveness, not another agent's work.
            let stoppedHere = context.hasUnseenStop && (context.agentPaneID == nil || context.agentPaneID == session)
            return AgentLogo(id: agent.id, session: session, provider: agent.provider,
                title: SidebarAgentTitle.display(terminalTitle: leaf?.title ?? "", agentName: agent.name, tabProvider: agent.provider),
                status: AgentTileStatus(needsInput: needsInput, isBusy: leaf?.isBusy == true && !stoppedHere,
                    isCompleted: agent.isCompleted, isCached: isCached, question: context.question(session: session),
                    result: agent.result, statusLabel: AgentAssignmentStatus(agent: agent, needsInput: needsInput).label))
        }
    }

    /// The navigation target that opens this agent's worktree on its pane. Its
    /// id has a pane item's form, because a host that publishes pane ids routes
    /// a pane by that id. A finished agent has no live pane, so its target is
    /// the worktree.
    public func activityItem(in worktree: WorktreePanes) -> SidebarActivityItem {
        let projectID = SidebarProjection.projectID(worktree)
        let stable = worktree.sidebar?.id ?? "\(projectID):\(worktree.path)"
        let isLive = worktree.layout?.leaves.contains { $0.sessionName == session } == true
        return SidebarActivityItem(id: "\(stable):\(worktree.sidebar?.paneIDs?[session] ?? session)", projectID: projectID,
            worktreeID: worktree.path, paneID: isLive ? session : nil, projectName: worktree.repoDisplayName,
            worktreeName: worktree.displayName, title: title, occurrence: nil, isBusy: status.dot == .working)
    }
}

/// @spec LAYOUT-2.254
/// While a worktree has two or more agents that have not finished, the application shall show one provider logo per such agent beneath its sidebar icon, at most five followed by a count, leave finished agents out, ring a logo in orange while its agent asks for user input and in pulsing blue while it works, and draw a ringed logo above its neighbours with the asking one on top.
public enum AgentLogoStackModel {
    public static func visible(_ logos: [AgentLogo], limit: Int = 5) -> (shown: [AgentLogo], overflow: Int) {
        let logos = logos.filter { !$0.status.isFinished }
        guard logos.count >= 2 else { return ([], 0) }
        return (Array(logos.prefix(limit)), max(0, logos.count - limit))
    }

    public static func zOrder(_ logo: AgentLogo) -> Double {
        switch logo.status.dot {
        case .asking?: 2
        case .working?: 1
        case nil: 0
        }
    }
}

/// A worktree's agents as small overlapping provider logos. Hovering (or, on
/// touch, tapping) spreads them apart; each then names its terminal and
/// selects its agent.
public struct AgentLogoStack: View {
    static let size: CGFloat = 18
    let logos: [AgentLogo]
    let background: Color
    /// The worktree icon's primary colour, which then fills each logo (LAYOUT-2.264).
    let tint: Color?
    let onSelect: (String) -> Void
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(logos: [AgentLogo], background: Color, tint: Color? = nil, onSelect: @escaping (String) -> Void) {
        self.logos = logos; self.background = background; self.tint = tint; self.onSelect = onSelect
    }

    public var body: some View {
        let (shown, overflow) = AgentLogoStackModel.visible(logos)
        if !shown.isEmpty {
            HStack(spacing: expanded ? 4 : -5) {
                ForEach(shown) { logo in
                    logoView(logo)
                        .zIndex(AgentLogoStackModel.zOrder(logo))
                }
                if overflow > 0 {
                    Text("+\(overflow)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.leading, expanded ? 0 : 7)
                }
            }
            .padding(expanded ? 3 : 0)
            .background {
                if expanded {
                    Capsule().fill(background).shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: expanded)
            #if os(macOS)
            .onHover { expanded = $0 }
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agents")
        }
    }

    private func logoView(_ logo: AgentLogo) -> some View {
        let isDark = colorScheme == .dark
        let haloColor: Color? = switch logo.status.dot {
        case .asking?: AgentStatusDot.asking
        case .working?: AgentStatusDot.working(isDark: isDark)
        case nil: nil
        }
        return AgentProviderIcon(provider: logo.provider, size: 12)
            .foregroundStyle(tint == nil ? Color.primary.opacity(0.9) : Color.white)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(tint ?? Color.primary.opacity(isDark ? 0.18 : 0.1)).background(Circle().fill(background)))
            .overlay {
                if let haloColor {
                    AgentStatusPulse(reduceMotion: reduceMotion || logo.status.dot == .asking) { opacity in
                        // A plain ring: a glow blurs a mark this small.
                        Circle().strokeBorder(haloColor, lineWidth: 1.5)
                            .opacity(opacity)
                    }
                } else {
                    Circle().strokeBorder(background, lineWidth: 1.5)
                }
            }
            .opacity(logo.status.isDimmed ? 0.45 : 1)
            .scaleEffect(expanded ? 1.1 : 1)
            .contentShape(Circle())
            .help(logo.title)
            .onTapGesture {
                #if os(macOS)
                onSelect(logo.id)
                #else
                if expanded { onSelect(logo.id); expanded = false } else { expanded = true }
                #endif
            }
            .accessibilityElement()
            .accessibilityLabel(Text(logo.title))
            .accessibilityValue(Text(logo.status.caption))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSelect(logo.id) }
    }
}
