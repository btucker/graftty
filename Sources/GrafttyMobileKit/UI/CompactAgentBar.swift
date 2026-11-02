#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyCommandUI

/// A floating agent switcher. Its menu also owns New agent so creation state
/// and failure alerts outlive the native menu's dismissal.
struct CompactAgentBar: View {
    let worktree: WorktreePanes
    let session: String
    let onSelect: (String) -> Void
    var onNewAgent: ((String) -> Void)? = nil
    var onOpenTerminal: (() -> Void)? = nil
    var attentionContext: SidebarWorktreeContext? = nil
    var hostID: UUID? = nil
    var host: Host? = nil
    var theme: GhosttyThemeColors = .fallback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var agents: [AgentSessionInfo] { worktree.agents?.filter { $0.presentationSessionName != nil } ?? [] }
    private var selectedAgent: AgentSessionInfo? { agents.first { $0.presentationSessionName == session } }

    var body: some View {
        Group {
            if let host {
                MobileNewAgentMenu(host: host, worktree: worktree.path, onSelect: onNewAgent ?? onSelect,
                    menuContent: AnyView(agentsMenu), label: AnyView(switcherLabel))
            } else {
                Menu { agentsMenu } label: { switcherLabel }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityIdentifier("workspace.agent.switcher")
    }

    private var agentsMenu: some View {
        Section(worktree.displayName) {
            ForEach(agents) { agent in
                if let target = agent.presentationSessionName {
                    Button { onSelect(target) } label: {
                        Label {
                            Text("\(worktree.workspaceSessionTitle(target)) · \(AgentAssignmentStatus(agent: agent, needsInput: context.needsInput(session: target)).label)")
                                .foregroundStyle(agent.isCompleted ? .secondary : .primary)
                        } icon: {
                            Image(systemName: AgentAssignmentStatus(agent: agent,
                                needsInput: context.needsInput(session: target)).systemImage)
                        }
                    }
                }
            }
            if let onOpenTerminal {
                Divider()
                Button("Terminal", systemImage: "apple.terminal", action: onOpenTerminal)
                    .accessibilityIdentifier("workspace.terminal.open")
            }
        }
    }

    private var switcherLabel: some View {
        HStack(spacing: 6) {
            if let selectedAgent {
                MobileAgentStatusBadge(agent: selectedAgent, hostID: hostID,
                    needsInput: context.needsInput(session: session),
                    isBusy: worktree.layout?.leaves.first { $0.sessionName == session }?.isBusy)
            } else {
                Image(systemName: "terminal")
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Text(selectedAgent == nil ? "Agents" : worktree.workspaceSessionTitle(session))
                    .lineLimit(1).truncationMode(.tail)
            }
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.callout)
        .padding(.leading, 4).padding(.trailing, 12)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Agents, \(selectedAgent == nil ? worktree.displayName : worktree.workspaceSessionTitle(session))")
    }
    private var context: SidebarWorktreeContext { attentionContext ?? SidebarWorktreeContext(worktree: worktree) }
}

struct MobileAgentStatusBadge: View {
    let agent: AgentSessionInfo
    let hostID: UUID?
    let needsInput: Bool
    /// The pane's turn activity; nil when unknown (AGENT-2.7).
    var isBusy: Bool? = nil
    @Environment(\.retainedMobilePanes) private var retainedPanes

    private var disconnected: Bool {
        guard let hostID, let session = agent.sessionName,
              let client = retainedPanes?.cached(.init(hostID: hostID, sessionName: session))?.client else { return false }
        return client.connectionState != .live
    }

    var body: some View {
        AgentStatusBadge(status: agent.status, needsInput: needsInput, failure: agent.failure,
                         disconnected: disconnected, processObservation: agent.processObservation, isBusy: isBusy)
    }
}
#endif
