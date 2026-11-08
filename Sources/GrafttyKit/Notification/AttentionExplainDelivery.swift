import Foundation
import GrafttyProtocol

/// @spec AGENT-3.40
/// Explain more on a client becomes an ordinary send-pane request on the host,
/// so both the Mac and headless hosts type into the pane the way `graftty pane send` does.
public enum AttentionExplainDelivery {
    /// The send-pane request for the pane whose session is `paneID`, or nil when it isn't in that worktree.
    public static func message(in state: AppState, worktreeID: String, paneID: String) -> NotificationMessage? {
        guard let worktree = state.worktree(forPath: worktreeID),
              let slot = worktree.paneSlot(forSessionName: paneID),
              let index = worktree.splitTree.allLeaves.firstIndex(of: slot) else { return nil }
        return .sendPane(path: worktreeID, index: index + 1, text: AttentionExplainPrompt.text, pressEnter: true)
    }

    @MainActor
    public static func deliver(worktreeID: String, paneID: String, state: AppState,
                               platform: any ControlPlatform) async -> WorktreeManagementResponse {
        guard let message = message(in: state, worktreeID: worktreeID, paneID: paneID) else {
            return .error(code: "not-found", message: "This agent's pane is no longer open.", forceAllowed: false, shortStatus: nil)
        }
        switch await platform.handlePlatformRequest(message) {
        case .ok?: return .ok
        case .error(let message)?:
            return .error(code: "explain-failed", message: message, forceAllowed: false, shortStatus: nil)
        default:
            return .error(code: "explain-failed", message: "The host couldn't type into this pane.", forceAllowed: false, shortStatus: nil)
        }
    }
}
