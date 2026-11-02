import GrafttyCommandUI
import GrafttyProtocol

/// Resolve question placement against the panes actually displayed in the list.
struct MobileWorktreeRowPresentation {
    let leaves: [PaneLayoutNode.Leaf]
    let worktreeAttentionCount: Int
    let questionPaneID: String?
    let showsWorktreeQuestion: Bool

    init(context: SidebarWorktreeContext, workspace: WorkspaceLayout<String>? = nil) {
        let leaves = context.worktree.sidebarAgentLeaves(in: workspace ?? .initial(for: context.worktree))
        self.leaves = leaves
        let sessions = Set(leaves.map(\.sessionName))
        worktreeAttentionCount = context.pending.filter { $0.paneID.map(sessions.contains) != true }.count
        questionPaneID = context.question == nil ? nil : context.questionPaneID.flatMap { route in
            leaves.contains { $0.sessionName == route } ? route : nil
        }
        showsWorktreeQuestion = context.question != nil && questionPaneID == nil
    }
}
