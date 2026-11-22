import GrafttyKit
import GrafttyProtocol

/// The Chat / Terminal choice for a local agent tab.
enum WorkspaceChatSwitch {
    /// Records this viewer's view of a tab. Only the layout changes: the tab,
    /// its terminal session, its agent, and its conversation stay as they are,
    /// and nothing is sent to the agent.
    static func setView(chat: Bool, slot: PaneSlotID, in worktree: inout WorktreeEntry, chatAvailable: Bool) {
        guard chatAvailable || !chat else { return }
        worktree.ensureWorkspaceLayout()
        guard var layout = worktree.workspaceLayout else { return }
        layout.setShowsChat(chat, for: slot)
        worktree.workspaceLayout = layout
    }

    /// Changes when a tab's agent, state, or conversation changes, so the
    /// switch is offered again only after the host confirms Chat can attach.
    static func availabilityKey(_ worktree: WorktreeEntry) -> String {
        worktree.agents
            .map { "\($0.id)/\($0.status.rawValue)/\($0.providerSessionID ?? "")/\($0.paneSlotID?.id.uuidString ?? "")" }
            .joined(separator: "|")
    }
}
