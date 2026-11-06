import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarAttentionDismissalTests {
    private func asking(at time: Double = 100) -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: time),
            recap: .init(title: "Reconnect", completed: "Reproduced", next: "Implement", need: "Retry silently?"),
            providerSessionKey: "agent")
        return .init(path: "/wt", displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
                     state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                     layout: nil, sidebar: .init(id: "/wt", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop))
    }

    @Test("@spec LAYOUT-2.216: While a worktree row needs the user, the application shall offer Dismiss Request in that row's menu, and dismissing shall move the row out of Needs You until a later request arrives.")
    func dismissalIsOfferedOnlyWhileTheRowNeedsYou() {
        let navigation = SidebarNavigationState(prefix: "dismissal.\(UUID())")
        let row = asking()
        let context = navigation.worktreeContext(row)
        #expect(SidebarRowStatus.resolve(context: context, worktree: row, isAsleep: false).needsAttention)
        #expect(SidebarAttentionDismissal.isAvailable(context))
        #expect(SidebarAttentionDismissal.title == "Dismiss Request")

        navigation.dismissRequest(in: context)
        let dismissed = navigation.worktreeContext(row)
        #expect(!SidebarRowStatus.resolve(context: dismissed, worktree: row, isAsleep: false).needsAttention)
        #expect(!SidebarAttentionDismissal.isAvailable(dismissed))

        let later = asking(at: 200)
        #expect(SidebarAttentionDismissal.isAvailable(navigation.worktreeContext(later)))
    }

    @Test func retiringSkipsClearedRequestsAndStopsAtTheFirstFailure() async throws {
        let requests: [WorktreeManagementRequest] = ["cleared", "refused", "unsent"].map {
            .acknowledge(worktreeID: $0, paneID: nil)
        }
        var sent: [String] = []
        let message = try await SidebarAttentionDismissal.retire(requests) { request in
            guard case let .acknowledge(worktreeID, _) = request else { return .ok }
            sent.append(worktreeID)
            return .error(code: worktreeID == "cleared" ? "occurrence-changed" : "denied", message: worktreeID,
                          forceAllowed: false, shortStatus: nil)
        }
        #expect(message == "refused")
        #expect(sent == ["cleared", "refused"])
        #expect(try await SidebarAttentionDismissal.retire(requests) { _ in .ok } == nil)
    }
}
