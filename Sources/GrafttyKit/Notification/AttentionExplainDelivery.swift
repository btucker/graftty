import Foundation
import GrafttyProtocol

/// Explain more on a client becomes an ordinary send-pane request on the host,
/// so both the Mac and headless hosts type into the pane the way `graftty pane send` does.
/// @spec AGENT-3.40: When a client asks a host to explain a stopped agent's question, the host shall type the catch-up prompt into that agent's pane and submit it, and shall refuse a pane it cannot find or one waiting at its harness's own prompt.
public enum AttentionExplainDelivery {
    /// Reads the platform's live state, so the pane index and the send it
    /// addresses come from the same main-actor turn.
    @MainActor
    public static func deliver(worktreeID: String, paneID: String,
                               platform: any ControlPlatform) async -> WorktreeManagementResponse {
        guard let worktree = platform.state.worktree(forPath: worktreeID),
              let slot = worktree.paneSlot(forSessionName: paneID),
              let index = worktree.splitTree.allLeaves.firstIndex(of: slot) else {
            return .error(code: "not-found", message: "This agent's pane is no longer open.", forceAllowed: false, shortStatus: nil)
        }
        // A permission or question prompt owns the input: Enter would answer it.
        guard worktree.paneAttention[slot]?.source != .agentStop else {
            return .error(code: "agent-prompting", message: "This agent is waiting at a prompt. Open it to answer.", forceAllowed: false, shortStatus: nil)
        }
        let message = NotificationMessage.sendPane(path: worktreeID, index: index + 1, text: AttentionExplainPrompt.text, pressEnter: true)
        switch await platform.handlePlatformRequest(message) {
        case .ok?: return .ok
        case .error(let message)?:
            return .error(code: "explain-failed", message: message, forceAllowed: false, shortStatus: nil)
        default:
            return .error(code: "explain-failed", message: "The host couldn't type into this pane.", forceAllowed: false, shortStatus: nil)
        }
    }
}
