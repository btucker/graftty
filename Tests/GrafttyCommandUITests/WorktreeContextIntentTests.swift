import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct WorktreeContextIntentTests {
    @Test("@spec CONTEXT-79: When a stopped question's pane cannot be resolved, the application shall preserve its unresolved route rather than borrowing another pane's provider request.")
    func unresolvedQuestionDoesNotBorrowAnotherRequest() {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(),
            recap: .init(title: "Fix", completed: "Checked.", next: "Decide.", need: "Ship?"), paneSlotID: "missing")
        let row = WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project", displayBranch: "wt",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: .leaf(sessionName: "other", title: "Other", attentionText: "Permission needed", isBusy: false, attentionSource: .agentStop),
            sidebar: .init(id: "wt", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop))
        let context = SidebarWorktreeContext(worktree: row)
        #expect(context.question == "Ship?")
        #expect(context.questionPaneID == nil)
    }

    @Test("@spec CONTEXT-80: When the host acknowledges a notice, the application shall remove its retained navigation item and dismissal marker from authoritative snapshots while preserving unacknowledged notices as pending during provider progress.")
    func acknowledgedNoticesRetireFromNavigationStorage() throws {
        var metadata = SidebarWorktreeMetadata(id: "wt", projectID: "p", agentProgressTimes: ["one": 102])
        let notice = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 100),
            recap: .init(update: .init(attention: .init(kind: .notice, message: "Ready to review."))), providerSessionKey: "one")
        func row(_ metadata: SidebarWorktreeMetadata) -> WorktreePanes {
            .init(path: "/wt", displayName: "wt", repoDisplayName: "Project", displayBranch: "wt",
                state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil, sidebar: metadata)
        }
        metadata.unreadAgentNotices = [notice]
        var workspace = SidebarAttentionWorkspace()
        workspace.reconcile(worktrees: [row(metadata)])
        #expect(workspace.items.count == 1)
        #expect(workspace.items.first?.isBusy == false)
        let item = try #require(workspace.items.first)
        var dismissed = workspace
        dismissed.dismissOccurrence(item)
        metadata.unreadAgentNotices = []
        workspace.reconcile(worktrees: [row(metadata)])
        dismissed.reconcile(worktrees: [row(metadata)])
        #expect(workspace.items.count == 1, "An unavailable or incomplete snapshot must not retire notices")
        #expect(dismissed.isDismissed(item))
        workspace.reconcile(worktrees: [row(metadata)], availableProjectIDs: ["p"])
        dismissed.reconcile(worktrees: [row(metadata)], availableProjectIDs: ["p"])
        #expect(workspace.items.isEmpty)
        #expect(!dismissed.isDismissed(item))
    }

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
