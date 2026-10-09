import Foundation
import Testing
@testable import GrafttyProtocol

struct SidebarInteractionPolicyTests {
    @Test("Opening agent requests preserves them while explicit dismissal and notification acknowledgement still work", arguments: [true, false])
    func openingDoesNotDismissAgentRequests(paneScoped: Bool) {
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let occurrence = SidebarAttentionOccurrence(timestamp: timestamp, text: "Choose a branch", source: .agentStop)
        var item = SidebarActivityItem(id: "request", projectID: "project", worktreeID: "/worktree",
            paneID: paneScoped ? "agent" : nil, projectName: "Project", worktreeName: "Task",
            title: "Choose a branch", occurrence: occurrence, isBusy: false)
        #expect(SidebarInteractionPolicy.acknowledgementOnOpen(for: item, supportsExactAcknowledgement: true) == nil)
        #expect(SidebarInteractionPolicy.acknowledgement(for: item, supportsExactAcknowledgement: true)
            == .acknowledgeOccurrence(worktreeID: item.worktreeID, paneID: item.paneID, occurrence: occurrence))
        item.occurrence?.source = .userNotify
        #expect(SidebarInteractionPolicy.acknowledgementOnOpen(for: item, supportsExactAcknowledgement: true) != nil)
        #expect(SidebarInteractionPolicy.acknowledgementOnOpen(for: item, supportsExactAcknowledgement: false) == nil)
    }

    @Test("@spec REMOTE-14.10: When an attention target is opened on an owner without exact acknowledgement support, the application shall preserve host attention rather than acknowledge unrelated or newer requests.")
    func safeAcknowledgement() {
        let item = SidebarActivityItem(id: "w", projectID: "p", worktreeID: "route", paneID: nil, projectName: "Project", worktreeName: "Worktree", title: "Review", occurrence: .init(timestamp: Date(), text: "Review", source: .agentStop), isBusy: false)
        #expect(SidebarInteractionPolicy.acknowledgement(for: item, supportsExactAcknowledgement: false) == nil)
        #expect(SidebarInteractionPolicy.acknowledgement(for: item, supportsExactAcknowledgement: true) == .acknowledgeOccurrence(worktreeID: item.worktreeID, paneID: nil, occurrence: item.occurrence!))
        var busy = item
        busy.occurrence = nil
        #expect(SidebarInteractionPolicy.acknowledgement(for: busy, supportsExactAcknowledgement: true) == nil)
    }

    @Test("@spec LAYOUT-2.46: When a user searches worktrees, the application shall match the displayed worktree name, repository name, or branch, including snapshots without branch metadata.")
    func displayedNameSearch() {
        let row = WorktreePanes(path: "opaque", displayName: "Billing review", repoDisplayName: "Accounting", displayBranch: "feature/123", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)
        #expect(SidebarInteractionPolicy.matches(row, query: "BILLING"))
        #expect(SidebarInteractionPolicy.matches(row, query: "accounting"))
        #expect(SidebarInteractionPolicy.matches(row, query: "123"))
        #expect(!SidebarInteractionPolicy.matches(row, query: "missing"))
        let legacy = WorktreePanes(path: "opaque", displayName: "Billing review", repoDisplayName: "Accounting", displayBranch: "", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)
        #expect(SidebarInteractionPolicy.matches(legacy, query: "Billing"))
    }
}
