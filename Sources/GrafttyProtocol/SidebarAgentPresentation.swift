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
    /// The agent whose conversation the host can show in Chat for this tab.
    /// Nil for a host that does not serve Chat, another provider, and a
    /// finished agent.
    func chatAgent(session: String) -> AgentSessionInfo? {
        agents?.first { $0.sessionName == session && $0.chatAvailable == true && !$0.isCompleted }
    }

    func workspaceSessionTitle(_ session: String) -> String {
        let agent = agents?.first { $0.presentationSessionName == session }
        return SidebarAgentTitle.display(
            terminalTitle: layout?.leaves.first { $0.sessionName == session }?.title ?? "",
            agentName: agent?.name ?? "Terminal", tabProvider: agent?.provider)
    }
}
