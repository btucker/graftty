import GrafttyCommandUI
import GrafttyProtocol

/// Resolve question placement against the panes actually displayed in the list.
struct MobileWorktreeRowPresentation {
    let leaves: [PaneLayoutNode.Leaf]
    let worktreeAttentionCount: Int
    let questionPaneID: String?
    let showsWorktreeQuestion: Bool

    init(context: SidebarWorktreeContext) {
        let leaves = context.worktree.state == .running ? context.worktree.layout?.leaves ?? [] : []
        self.leaves = leaves
        worktreeAttentionCount = leaves.isEmpty ? context.pending.count : 0
        questionPaneID = context.question == nil ? nil : context.questionPaneID.flatMap { route in
            leaves.contains { $0.sessionName == route } ? route : nil
        }
        showsWorktreeQuestion = context.question != nil && questionPaneID == nil
    }
}
