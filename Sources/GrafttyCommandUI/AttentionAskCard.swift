import Foundation
import GrafttyProtocol

/// One card in the mobile ask deck: the question, what the user needs to answer
/// it, and what Explain more does for it.
/// @spec IOS-13.20: While a worktree's agent has stopped with a question, its ask card shall show the question, the agent's catch-up or else what it last completed, and Explain more shall send the catch-up prompt to that agent's pane and open that pane at once.
public struct AttentionAskCard: Equatable, Sendable {
    public enum Explain: Equatable, Sendable {
        /// The agent stopped at its own input: type the catch-up prompt there, then open it.
        case sendPrompt(paneID: String)
        /// A harness prompt owns the input (IOS-13.21): open the pane only.
        case openOnly
    }

    public let question: String
    public let catchUp: String?
    /// Shown when the agent wrote no catch-up.
    public let lastCompleted: String?
    public let agentName: String?
    public let explain: Explain
    /// The request Open and Explain more land on: the one asking, even when
    /// another request in the worktree lists first (IOS-13.21).
    public let openTarget: SidebarActivityItem

    public init?(context: SidebarWorktreeContext) {
        guard let question = context.question else { return nil }
        self.question = question
        openTarget = context.questionItem ?? context.item
        catchUp = context.questionCatchUp
        let completed = context.brief?.completed.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastCompleted = catchUp == nil && !completed.isEmpty ? completed : nil
        agentName = context.item.agentStop?.agentName
        if context.questionIsStoppedTurn, let pane = context.questionPaneID {
            explain = .sendPrompt(paneID: pane)
        } else {
            explain = .openOnly
        }
    }
}
