#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyCommandUI

/// The compact agent switcher stays above live, loading, and completed content.
struct CompactAgentBar: View {
    let worktree: WorktreePanes
    let session: String
    let onSelect: (String) -> Void
    var hostID: UUID? = nil
    var theme: GhosttyThemeColors = .fallback

    private var agents: [AgentSessionInfo] { worktree.agents?.filter { $0.presentationSessionName != nil } ?? [] }
    private var selectedAgent: AgentSessionInfo? { agents.first { $0.presentationSessionName == session } }

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(agents) { agent in
                    if let target = agent.presentationSessionName {
                        Button { onSelect(target) } label: {
                            Label {
                                Text("\(agent.name) · \(AgentAssignmentStatus(agent: agent, needsInput: false).label)")
                                    .foregroundStyle(agent.isCompleted ? .secondary : .primary)
                            } icon: { AgentProviderIcon(provider: agent.provider) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    AgentProviderIcon(provider: selectedAgent?.provider)
                    Text(selectedAgent?.name ?? "Agents").lineLimit(1)
                    if let selectedAgent {
                        MobileAgentStatusBadge(agent: selectedAgent, hostID: hostID,
                            needsInput: worktree.layout?.leaves.first { $0.sessionName == session }?.attentionSource == .agentStop)
                    }
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }.disabled(agents.isEmpty)
            Spacer(minLength: 0)
        }.font(.callout).buttonStyle(.plain).padding(.horizontal, 14).frame(minHeight: 44)
            .foregroundStyle(theme.foreground).background(theme.background)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

struct MobileAgentStatusBadge: View {
    let agent: AgentSessionInfo
    let hostID: UUID?
    let needsInput: Bool
    @Environment(\.retainedMobilePanes) private var retainedPanes

    private var disconnected: Bool {
        guard let hostID, let session = agent.sessionName,
              let client = retainedPanes?.cached(.init(hostID: hostID, sessionName: session))?.client else { return false }
        return client.connectionState != .live
    }

    var body: some View {
        AgentStatusBadge(status: agent.status, needsInput: needsInput, failure: agent.failure,
                         disconnected: disconnected, processObservation: agent.processObservation)
    }
}
#endif
