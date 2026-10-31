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
                            Label { Text(agent.name) } icon: { AgentProviderIcon(provider: agent.provider) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    AgentProviderIcon(provider: selectedAgent?.provider)
                    Text(selectedAgent?.name ?? "Agents").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }.disabled(agents.isEmpty)
            Spacer(minLength: 0)
            if selectedAgent == nil, let target = lastAgent ?? agents.first?.sessionName {
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
#endif
