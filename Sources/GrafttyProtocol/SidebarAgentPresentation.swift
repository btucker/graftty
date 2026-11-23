import Foundation

public enum SidebarAgentTitle {
    public static func display(terminalTitle: String, agentName: String?, tabProvider: String? = nil) -> String {
        if let glyph = terminalTitle.first, let tabProvider {
            // These providers put a rotating, space-delimited glyph in their OSC title.
            let isSpinner = switch tabProvider {
            case "codex": "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(glyph)
            case "claude": "◐◑".contains(glyph)
            default: false
            }
            let remainder = terminalTitle.dropFirst()
            if isSpinner, remainder.first?.isWhitespace != false {
                let title = remainder.drop(while: \.isWhitespace)
                return title.isEmpty ? agentName ?? "" : String(title)
            }
        }
        return terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? agentName ?? "" : terminalTitle
    }
}

public extension WorktreePanes {
    func sidebarAgentLeaves(in workspace: WorkspaceLayout<String>) -> [PaneLayoutNode.Leaf] {
        guard state == .running || state == .closed, !showsCreationProgress else { return [] }
        let live = Dictionary((layout?.leaves ?? []).map { ($0.sessionName, $0) },
            uniquingKeysWith: { first, _ in first })
        let agentsBySession = Dictionary((agents ?? []).compactMap { agent in
            agent.presentationSessionName.map { ($0, agent) }
        }, uniquingKeysWith: { first, _ in first })
        return workspace.canvasSessions.compactMap { session in
            guard let agent = agentsBySession[session] else { return nil }
            guard state == .running || agent.isCompleted else { return nil }
            if let leaf = live[session] { return leaf }
            guard agent.isCompleted else { return nil }
            return .init(sessionName: session, title: agent.name, attentionText: nil,
                isBusy: false, attentionSource: nil, attentionTimestamp: nil)
        }
    }

    func workspaceSessionTitle(_ session: String) -> String {
        let agent = agents?.first { $0.presentationSessionName == session }
        return SidebarAgentTitle.display(
            terminalTitle: layout?.leaves.first { $0.sessionName == session }?.title ?? "",
            agentName: agent?.name ?? "Terminal", tabProvider: agent?.provider)
    }

    var sidebarAgentLeaves: [PaneLayoutNode.Leaf] {
        sidebarAgentLeaves(in: .initial(for: self))
    }
}
