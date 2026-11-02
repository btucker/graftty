#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyCommandUI

/// The compact agent switcher stays above live, loading, and completed content.
struct CompactAgentBar: View {
    let worktree: WorktreePanes
    let session: String
    let onSelect: (String) -> Void
    var attentionContext: SidebarWorktreeContext? = nil
    var hostID: UUID? = nil
    var host: Host? = nil
    var theme: GhosttyThemeColors = .fallback

    private var agents: [AgentSessionInfo] { worktree.agents?.filter { $0.presentationSessionName != nil } ?? [] }
    private var selectedAgent: AgentSessionInfo? { agents.first { $0.presentationSessionName == session } }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 14) {
            Menu {
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
            } label: {
                HStack(spacing: 6) {
                    if let selectedAgent {
                        MobileAgentStatusBadge(agent: selectedAgent, hostID: hostID,
                            needsInput: context.needsInput(session: session),
                            isBusy: worktree.layout?.leaves.first { $0.sessionName == session }?.isBusy)
                    } else {
                        Image(systemName: "terminal")
                    }
                    Text(selectedAgent == nil ? "Agents" : worktree.workspaceSessionTitle(session)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }.disabled(agents.isEmpty)
            Spacer(minLength: 0)
            if let host {
                MobileNewAgentMenu(host: host, worktree: worktree.path, onSelect: onSelect)
                WorktreePreviewMenu(host: host, worktree: worktree.path)
            }
        }.font(.callout).buttonStyle(.plain).padding(.horizontal, 14).frame(minHeight: 44)
            .foregroundStyle(theme.foreground).background(theme.background)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
        WorkspaceInputRequest(context: context, selectedSession: session, onSelect: onSelect)
            .foregroundStyle(theme.foreground).background(theme.background)
        }
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
