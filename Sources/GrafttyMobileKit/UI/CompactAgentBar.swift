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
    @Environment(\.openWorktreeContext) private var openContext

    /// @spec IOS-13.17: While a terminal is open, the application shall name its worktree and host under the agent's name, because nothing else on that screen says where it is.
    static func location(worktree: WorktreePanes, hostLabel: String?) -> String {
        ([worktree.displayName, worktree.origin?.deviceLabel ?? hostLabel].compactMap { $0 }).joined(separator: " · ")
    }

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
            if let openContext {
                Button("About this worktree", systemImage: "info.circle") { openContext() }
                    .accessibilityIdentifier("workspace.about.open")
            }
        }
    }

    private var switcherLabel: some View {
        HStack(spacing: 6) {
            // IOS-13.19: no status beside the open agent; the terminal shows
            // whether it's working, and the menu keeps each agent's status.
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
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.callout)
        .padding(.leading, 4).padding(.trailing, 12)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Agents, \(selectedAgent == nil ? worktree.displayName : worktree.workspaceSessionTitle(session)), \(Self.location(worktree: worktree, hostLabel: host?.label))")
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
