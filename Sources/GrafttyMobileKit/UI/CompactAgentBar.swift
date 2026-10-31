#if canImport(UIKit)
import SwiftUI
import GrafttyProtocol
import GrafttyCommandUI

/// Compact workspaces open the selected terminal full-height. Switching only
/// changes this device's navigation; the host keeps every session alive.
struct CompactAgentBar: View {
    let worktree: WorktreePanes
    let session: String
    let onSelect: (String) -> Void
    let lastAgent: String?
    var onNewTerminal: (() -> Void)?
    var hostID: UUID? = nil

    private var agents: [AgentSessionInfo] { worktree.agents?.filter { $0.sessionName != nil && $0.status != "closed" } ?? [] }
    private var terminals: [PaneLayoutNode.Leaf] {
        let agentSessions = Set(agents.compactMap(\.sessionName))
        return worktree.layout?.leaves.filter { !agentSessions.contains($0.sessionName) } ?? []
    }
    private var selectedAgent: AgentSessionInfo? { agents.first { $0.sessionName == session } }

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(agents) { agent in
                    if let target = agent.sessionName {
                        Button { onSelect(target) } label: {
                            Label {
                                Text("\(agent.name) · \(AgentAssignmentStatus(agent: agent, needsInput: false).label)")
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
            if selectedAgent == nil, let target = MobileWorkspaceStore.previousAgent(lastAgent, in: worktree) {
                Button { onSelect(target) } label: { Label("Back to agent", systemImage: "arrow.uturn.backward") }
            } else {
                Menu {
                    ForEach(terminals, id: \.sessionName) { terminal in
                        Button(terminal.displayTitle) { onSelect(terminal.sessionName) }
                    }
                    if let onNewTerminal { Button("New terminal", action: onNewTerminal) }
                } label: { Label("Terminal", systemImage: "terminal") }
                    .disabled(terminals.isEmpty && onNewTerminal == nil)
            }
        }.font(.callout).buttonStyle(.plain).padding(.horizontal, 14).frame(minHeight: 44)
            .background(.bar)
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
