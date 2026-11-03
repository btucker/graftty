import Foundation
import GrafttyProtocol

/// The one line a sidebar row shows under its name.
public enum SidebarRowStatus: Equatable, Sendable {
    case question(String, paneID: String?)
    case notification(String, paneID: String?)
    case working(String)
    /// `isUnread` keeps the text undimmed until the stopped turn is viewed.
    case whereWeAre(String, isUnread: Bool)
    case none

    public var needsAttention: Bool {
        switch self {
        case .question, .notification: return true
        case .whereWeAre(_, let isUnread): return isUnread
        case .working, .none: return false
        }
    }

    /// `isAsleep` means the row came from the host's last report: nothing is
    /// known to be running, so only the saved where-we-are text is meaningful.
    public static func resolve(context: SidebarWorktreeContext, worktree: WorktreePanes, isAsleep: Bool) -> SidebarRowStatus {
        let completed = context.brief?.completed.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A stop stays unread until viewed, whether or not it asked anything.
        // It outranks pane liveness, which lags behind it, unless the agent resumed.
        let hasUnreadStop = worktree.sidebar?.unseenAgentStop != nil && !context.isRunning
        func whereWeAre(isUnread: Bool) -> SidebarRowStatus {
            completed.isEmpty ? .none : .whereWeAre(completed, isUnread: isUnread)
        }
        if isAsleep { return whereWeAre(isUnread: false) }
        if let question = context.question { return .question(question, paneID: context.questionPaneID) }
        if let notice = context.pending.first(where: { $0.agentStop == nil && $0.occurrence?.source != .agentStop }),
           let text = notice.occurrence?.text {
            return .notification(text, paneID: notice.paneID)
        }
        let working = hasUnreadStop ? [] : (worktree.layout?.leaves ?? []).filter(\.isBusy)
        if working.count == 1 { return .working(working[0].displayTitle) }
        if working.count > 1 { return .working("\(working.count) agents working") }
        return whereWeAre(isUnread: hasUnreadStop)
    }
}
