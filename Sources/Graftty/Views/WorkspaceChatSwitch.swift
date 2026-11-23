import GrafttyKit
import GrafttyProtocol

/// The Chat / Terminal choice for a local agent tab.
enum WorkspaceChatSwitch {
    /// Records this viewer's view of a tab. Only the layout changes: the tab,
    /// its terminal session, its agent, and its conversation stay as they are,
    /// and nothing is sent to the agent.
    static func setView(chat: Bool, slot: PaneSlotID, in worktree: inout WorktreeEntry) {
        let offered = worktree.agents.contains { $0.presentationSlotID == slot && AgentChatHost.offers($0) }
        guard offered || !chat else { return }
        worktree.ensureWorkspaceLayout()
        guard var layout = worktree.workspaceLayout else { return }
        layout.setShowsChat(chat, for: slot)
        worktree.workspaceLayout = layout
    }
}
