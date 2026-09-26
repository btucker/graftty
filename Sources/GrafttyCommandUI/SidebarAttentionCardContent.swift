import Foundation
import GrafttyProtocol

/// @spec LAYOUT-2.73: When an agent recap is expanded in Attention, the card shall show the worktree name, a gray pane title beneath it, and task context, any user question, and the next step in that order.
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

/// @spec LAYOUT-2.79: While Needs You contains agent stops and other requests, the application shall group explicit recap questions first, keep stops without questions visible in compact rows, and retain other requests.
struct SidebarAttentionBuckets {
    let questions: [SidebarActivityItem]
    let stopped: [SidebarActivityItem]
    let other: [SidebarActivityItem]

    init(items: [SidebarActivityItem]) {
        var questions: [SidebarActivityItem] = []
        var stopped: [SidebarActivityItem] = []
        var other: [SidebarActivityItem] = []
        for item in items {
            if let need = item.agentStop?.recap?.need,
               !need.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                questions.append(item)
            } else if item.agentStop != nil {
                stopped.append(item)
            } else {
                other.append(item)
            }
        }
        self.questions = questions
        self.stopped = stopped
        self.other = other
    }
}
