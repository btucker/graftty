#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyCommandUI

/// The agent's name at the top of the phone's stage. Tapping it opens the
/// gallery, which lists every agent in the worktree (IOS-13.32).
struct CompactAgentBar: View {
    let worktree: WorktreePanes
    let session: String
    let onOpenGallery: () -> Void
    var host: Host? = nil
    var theme: GhosttyThemeColors = .fallback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// @spec IOS-13.17: While a terminal is open, the application shall name its worktree and host under the agent's name, because nothing else on that screen says where it is.
    static func location(worktree: WorktreePanes, hostLabel: String?) -> String {
        ([worktree.displayName, worktree.origin?.deviceLabel ?? hostLabel].compactMap { $0 }).joined(separator: " · ")
    }

    /// @spec IOS-13.31: While the phone shows one agent on stage and another agent in the worktree asks for user input that the stage's question bar does not already show, the application shall show a chip naming the asking agent, and tapping it shall put that agent on stage.
    static func askingChip(worktree: WorktreePanes, context: SidebarWorktreeContext, session: String) -> (session: String, title: String)? {
        for agent in worktree.agents ?? [] {
            guard let target = agent.presentationSessionName, target != session, !agent.isCompleted,
                  context.needsInput(session: target),
                  !(context.question != nil && context.questionPaneID == target) else { continue }
            return (target, worktree.workspaceSessionTitle(target))
        }
        return nil
    }

    private var selectedAgent: AgentSessionInfo? { worktree.agents?.first { $0.presentationSessionName == session } }

    var body: some View {
        Button(action: onOpenGallery) { label }
            .buttonStyle(.plain)
            .foregroundStyle(theme.foreground)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .accessibilityIdentifier("workspace.agent.switcher")
    }

    private var label: some View {
        HStack(spacing: 6) {
            // IOS-13.19: no status beside the open agent; the terminal shows
            // whether it's working, and the gallery shows each agent's status.
            if selectedAgent == nil {
                Image(systemName: "terminal")
            }
            if !dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedAgent == nil ? "Agents" : worktree.workspaceSessionTitle(session))
                        .lineLimit(1).truncationMode(.tail)
                    Text(Self.location(worktree: worktree, hostLabel: host?.label))
                        .font(.caption2).foregroundStyle(theme.foreground.opacity(0.65))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Image(systemName: "square.grid.2x2").font(.caption2)
        }
        .font(.callout)
        .padding(.leading, 4).padding(.trailing, 12)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Agents, \(selectedAgent == nil ? worktree.displayName : worktree.workspaceSessionTitle(session)), \(Self.location(worktree: worktree, hostLabel: host?.label))")
        .accessibilityHint("Shows every agent in this worktree")
    }
}

struct MobileAgentStatusBadge: View {
    let agent: AgentSessionInfo
    let hostID: UUID?
    let needsInput: Bool
    /// The pane's turn activity; nil when unknown (AGENT-2.7).
    var isBusy: Bool? = nil
    var placement: AgentStatusBadge.Placement = .tab
    @Environment(\.retainedMobilePanes) private var retainedPanes

    private var disconnected: Bool {
        guard let hostID, let session = agent.sessionName,
              let client = retainedPanes?.cached(.init(hostID: hostID, sessionName: session))?.client else { return false }
        return client.connectionState != .live
    }

    var body: some View {
        AgentStatusBadge(status: agent.status, needsInput: needsInput, failure: agent.failure,
                         disconnected: disconnected, processObservation: agent.processObservation,
                         isBusy: isBusy, placement: placement)
    }
}
#endif
