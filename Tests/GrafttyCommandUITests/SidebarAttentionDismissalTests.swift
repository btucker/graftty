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

    private func finished() -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 50),
            recap: .init(title: "Stop", completed: "Finished", next: "Next"), providerSessionKey: "agent")
        return .init(path: "/done", displayName: "Done", repoDisplayName: "Project", displayBranch: "done",
                     state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                     layout: nil, sidebar: .init(id: "/done", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop))
    }

    @Test("@spec LAYOUT-2.218: When the user dismisses a worktree's request or unopened finished turn on any client, the application shall retire it on the owning host, so no client keeps showing it under Needs You.")
    func dismissingAFinishedTurnRetiresItOnTheHost() {
        let row = finished()
        let context = SidebarWorktreeContext(worktree: row)
        #expect(context.pending.isEmpty)
        #expect(SidebarAttentionDismissal.isAvailable(context))
        let stop = row.sidebar!.unseenAgentStop!
        #expect(SidebarAttentionDismissal.requests(for: context, supportsExactAcknowledgement: true)
            == [.acknowledgeOccurrence(worktreeID: "/done", paneID: nil, occurrence: stop.occurrence)])
        #expect(SidebarAttentionDismissal.requests(for: context, supportsExactAcknowledgement: false).isEmpty)
        // A question from the same stop is one request, not two.
        let asked = SidebarWorktreeContext(worktree: asking())
        #expect(SidebarAttentionDismissal.requests(for: asked, supportsExactAcknowledgement: true).count == 1)
    }

    @Test("@spec LAYOUT-2.216: While a worktree row waits for the user, the application shall offer Dismiss Request in that row's or tile's menu, and dismissing shall move it out of Needs You until a later request or finished turn arrives.")
    func dismissalIsOfferedOnlyWhileTheRowNeedsYou() {
        let navigation = SidebarNavigationState(prefix: "dismissal.\(UUID())")
        let row = asking()
        let context = navigation.worktreeContext(row)
        #expect(SidebarRowStatus.resolve(context: context, worktree: row, isCached: false).needsAttention)
        #expect(SidebarAttentionDismissal.isAvailable(context))
        #expect(SidebarAttentionDismissal.title == "Dismiss Request")

        navigation.dismissRequest(in: context)
        let dismissed = navigation.worktreeContext(row)
        #expect(!SidebarRowStatus.resolve(context: dismissed, worktree: row, isCached: false).needsAttention)
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
