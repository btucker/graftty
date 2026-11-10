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

    /// A finished turn is unread, not a request: only these ask for something.
    public var needsAttention: Bool {
        switch self {
        case .question, .notification: return true
        case .whereWeAre, .working, .none: return false
        }
    }

    /// Everything waiting for the person: a request, or a finished turn they
    /// haven't opened. This is what Needs you, tile borders, and counts show.
    public var waitsForUser: Bool {
        switch self {
        case .question, .notification: return true
        case .whereWeAre(_, let isUnread): return isUnread
        case .working, .none: return false
        }
    }

    /// @spec LAYOUT-2.211
    /// How strongly to draw the row's identity. Emoji wash out faster against
    /// a light background, so light schemes fade a little less.
    public func identityOpacity(isDark: Bool) -> Double {
        switch self {
        case .question, .notification, .working: return 1
        // Everything in Needs you is at full strength.
        case .whereWeAre(_, let isUnread): return isUnread ? 1 : (isDark ? 0.55 : 0.6)
        case .none: return isDark ? 0.55 : 0.6
        }
    }

    /// Clicking the line goes to the pane that spoke, not just the worktree.
    public var opensPane: Bool {
        switch self {
        case .question: return true
        case .notification(_, let paneID): return paneID != nil
        case .working, .whereWeAre, .none: return false
        }
    }

    /// `isCached` means the row came from the host's last report: nothing is
    /// known to be running, so only the saved where-we-are text is meaningful.
    public static func resolve(context: SidebarWorktreeContext, worktree: WorktreePanes, isCached: Bool) -> SidebarRowStatus {
        let completed = context.brief?.completed.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A stop stays unread until viewed, whether or not it asked anything.
        // It outranks pane liveness, which lags behind it, unless the agent resumed.
        let hasUnreadStop = context.hasUnseenStop
        func whereWeAre(isUnread: Bool) -> SidebarRowStatus {
            // A stop without a recap still waits for the user, so it says who stopped.
            if completed.isEmpty, isUnread, let stop = worktree.sidebar?.unseenAgentStop { return .whereWeAre(stop.title, isUnread: true) }
            return completed.isEmpty ? .none : .whereWeAre(completed, isUnread: isUnread)
        }
        if isCached { return whereWeAre(isUnread: false) }
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
