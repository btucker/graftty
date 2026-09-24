import Foundation
import GrafttyProtocol

/// @spec LAYOUT-2.73: When a stopped agent has a recap, the Attention card shall show the worktree name, a gray pane title beneath it, and Context, Needs You, Up Next in that order; if no question exists it shall omit Needs You.
struct SidebarAttentionCardContent {
    struct Section: Identifiable {
        enum Kind: Hashable {
            case context
            case needsYou
            case upNext
        }

        let kind: Kind
        let text: String
        let detail: String?
        var id: Kind { kind }
    }

    let headerName: String
    let paneTitle: String?
    let title: String
    let sections: [Section]

    init(item: SidebarActivityItem) {
        headerName = item.worktreeName
        let recap = item.agentStop?.recap
        title = recap?.title ?? (item.agentStop == nil ? item.worktreeName : item.title)
        if let paneTitle = item.agentStop?.paneTitle,
           paneTitle != title, paneTitle != item.worktreeName,
           !paneTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.paneTitle = paneTitle
        } else {
            self.paneTitle = nil
        }
        if let recap {
            var sections = [Section(
                kind: .context,
                text: recap.context ?? recap.completed,
                detail: recap.context == nil ? nil : recap.completed
            )]
            if let need = recap.need {
                sections.append(Section(kind: .needsYou, text: need, detail: nil))
            }
            sections.append(Section(kind: .upNext, text: recap.next, detail: nil))
            self.sections = sections
        } else {
            sections = []
        }
    }
}
