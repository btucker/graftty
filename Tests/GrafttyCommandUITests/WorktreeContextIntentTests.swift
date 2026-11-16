import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct WorktreeContextIntentTests {
    @Test("@spec CONTEXT-73: While an unread agent notice exists on Mac or mobile, the application shall display it with dismissal controls and no answer field, including after the agent resumes or a newer routine turn ends.")
    func unreadNoticeRemainsVisibleWhileWorking() throws {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let notice = SidebarAgentStop(agentName: "Codex", stoppedAt: start,
            recap: .init(update: .init(attention: .init(kind: .notice, message: "Ready to review."))),
            providerSessionKey: "codex:one")
        let later = SidebarAgentStop(agentName: "Codex", stoppedAt: start.addingTimeInterval(2))
        var metadata = SidebarWorktreeMetadata(id: "wt", projectID: "p", lastAgentStop: later,
            agentProgressTimes: ["codex:one": 103])
        metadata.unreadAgentNotices = [notice]
        let row = WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project", displayBranch: "wt",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: metadata)
        let context = SidebarWorktreeContext(worktree: row, isViewed: { _ in true })
        #expect(context.pending.count == 1)
        #expect(context.question == nil)
        #expect(WorktreeContextPanel.sections(for: context, showsDetails: false).contains(.notices))
        #expect(!WorktreeContextPanel.sections(for: context, showsDetails: false).contains(.ask))
        #expect(SidebarRowStatus.resolve(context: context, worktree: row, isCached: false) == .notification("Ready to review.", paneID: nil))
        #expect(SidebarAttentionDismissal.requests(for: context, supportsExactAcknowledgement: true)
            == [.acknowledgeOccurrence(worktreeID: "/wt", paneID: nil, occurrence: notice.occurrence)])
        #expect(!SidebarRowStatus.whereWeAre("Tests passed.", isUnread: true).waitsForUser)

        let ask = SidebarAgentStop(agentName: "Codex", stoppedAt: start.addingTimeInterval(4),
            recap: .init(title: "Fix", completed: "Tested.", next: "Decide.", need: "Ship?"), providerSessionKey: "codex:one")
        metadata.unseenAgentStop = ask
        metadata.lastAgentStop = ask
        let asking = WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project", displayBranch: "wt",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: metadata)
        let sections = WorktreeContextPanel.sections(for: SidebarWorktreeContext(worktree: asking), showsDetails: false)
        #expect(try #require(sections.firstIndex(of: .notices)) < #require(sections.firstIndex(of: .ask)))
    }
}
