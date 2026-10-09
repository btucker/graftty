#if canImport(UIKit)
import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite("Mobile worktree reports")
@MainActor
struct MobileAttentionPaneTests {
    @Test("@spec IOS-9.14: While a mobile worktree identity is displayed at a narrow width, the application shall keep its name on one line and retain space for the information button and Git divergence.", arguments: [320.0, 393.0, 540.0])
    func longNamesDoNotInflateRows(width: Double) {
        func size(name: String) -> CGSize {
            let row = WorktreePanes(path: "/repo/feature", displayName: name, repoDisplayName: "graftty",
                displayBranch: name, state: .closed, isMainCheckout: false,
                prBadge: .init(number: 405, state: .open, checks: .success,
                    url: URL(string: "https://github.com/btucker/graftty/pull/405")!),
                stats: .init(ahead: 12, behind: 25, hasUncommittedChanges: true, baseRef: "main"),
                attentionText: nil, layout: nil)
            let hosted = UIHostingController(rootView: WorktreeBlock(worktree: row,
                theme: nil, isActive: false, isOpening: false, focusedPaneId: nil,
                projectColumn: true, context: SidebarWorktreeContext(worktree: row),
                onSelect: {}, onSelectPane: { _ in }, onReport: {}))
            return hosted.sizeThatFits(in: CGSize(width: width, height: 600))
        }
        let short = size(name: "feature")
        let long = size(name: "merge-recent-activity-attention-and-unified-worktree-reports")
        #expect(long.width <= width)
        #expect(long.height == short.height)
        #expect(long.height >= 44)
    }

    @Test("@spec IOS-9.13: When the user taps a mobile worktree's information button, the application shall show its report without selecting the worktree or acknowledging its request; the button shall provide a 44-point touch target.")
    func informationButtonOnlyPreviewsReport() {
        let navigation = SidebarNavigationState(prefix: "mobile-info.\(UUID())")
        let context = navigation.worktreeContext(worktree())
        var reportShown = false
        let button = MobileWorktreeReportButton(worktreeName: "push", onReport: { reportShown = true })
        button.activate()
        #expect(reportShown)
        #expect(!navigation.hasViewed(context.item))
        #expect(navigation.selectedProjectID == nil)
        let hosted = UIHostingController(rootView: button)
        let size = hosted.sizeThatFits(in: CGSize(width: 320, height: 640))
        #expect(size.width >= 44 && size.height >= 44)
    }

    @Test("@spec IOS-4.33: When a paired Mac sends a stopped-agent recap, GrafttyMobile shall display its full report in a presentation that fits a compact iPhone width.")
    func recapFitsPhoneReport() {
        let context = SidebarNavigationState(prefix: "mobile-report.\(UUID())").worktreeContext(worktree())
        let controller = UIHostingController(rootView: MobileWorktreeReportContent(context: context,
            onOpen: { true }, onDismiss: {}, onClose: {}))
        let size = controller.sizeThatFits(in: CGSize(width: 320, height: 640))
        #expect(size.width > 0 && size.width <= 320)
        #expect(size.height > 0 && size.height <= 640)
    }

    @Test("@spec LAYOUT-2.141: When a mobile worktree row recognizes a 500ms hold, the application shall show its report without selecting the worktree, acknowledging its request, or firing its terminal tap action.")
    func holdOpensOnlyReport() {
        let navigation = SidebarNavigationState(prefix: "mobile-hold.\(UUID())")
        let context = navigation.worktreeContext(worktree())
        var selected = false
        var reportShown = false
        let target = MobileWorktreeReportTarget(onOpen: {
            selected = true
            navigation.opened(context.item)
        }, onReport: { reportShown = true }) { Text("Worktree") }
        #expect(MobileWorktreeReportTarget<Text>.holdDuration == 0.5)
        target.activate(.first(true))
        #expect(reportShown)
        #expect(!selected)
        #expect(!navigation.hasViewed(context.item))
        target.activate(.second(()))
        #expect(selected)
        #expect(navigation.hasViewed(context.item))
    }

    @Test("@spec IOS-4.36: When a mobile worktree report is viewed, the application shall preserve its pending question until the agent resumes and retain the recap as a previous report afterward.")
    func reportSurvivesViewingAndResume() {
        let navigation = SidebarNavigationState(prefix: "mobile-retained.\(UUID())")
        var row = worktree()
        let pending = navigation.worktreeContext(row)
        #expect(pending.question != nil)
        navigation.opened(pending.item)
        let viewed = navigation.worktreeContext(row)
        #expect(viewed.question == pending.question)
        #expect(viewed.pending.count == pending.pending.count)
        #expect(viewed.item.agentStop?.recap == pending.item.agentStop?.recap)
        row = worktree(progressTimes: ["codex": 101])
        let resumed = navigation.worktreeContext(row)
        #expect(resumed.isRunning)
        #expect(resumed.question == nil)
        #expect(resumed.item.agentStop?.recap != nil)
    }

    @Test("@spec LAYOUT-2.142: When a mobile worktree search matches a retained report field, the application shall include that worktree without changing host-published order.")
    func searchIncludesViewedReportFields() {
        let navigation = SidebarNavigationState(prefix: "mobile-search.\(UUID())")
        let row = worktree()
        navigation.opened(navigation.worktreeContext(row).item)
        for query in ["client integration", "CI passed", "delivery on the phone", "Which device"] {
            #expect(navigation.worktreeContext(row).matches(query: query))
        }
        #expect(!navigation.worktreeContext(row).matches(query: "absent report field"))
    }

    @Test("@spec LAYOUT-2.144: While a mobile pane has a pending report question, the application shall show the full Needs your input question beneath the associated pane and suppress its duplicate status label.")
    func questionFitsWithoutTruncation() {
        let context = SidebarNavigationState(prefix: "mobile-question.\(UUID())").worktreeContext(worktree())
        #expect(context.questionPaneID == "session")
        #expect(context.question == "Which device should receive the test?")
        let view = UIHostingController(rootView: WorktreeBlock(worktree: context.worktree,
            theme: nil, isActive: false, isOpening: false, focusedPaneId: nil,
            context: context, onSelect: {}, onSelectPane: { _ in }, onReport: {}))
        #expect(view.sizeThatFits(in: CGSize(width: 280, height: 600)).height > 70)

    }

    private func worktree(progressTimes: [String: Double]? = nil) -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 100),
            recap: .init(title: "Paired-device push notifications",
                         context: "The client integration is committed.", completed: "CI passed.",
                         next: "Verify delivery on the phone.", need: "Which device should receive the test?"),
            paneTitle: "Verify push delivery")
        return WorktreePanes(path: "/repo/push", displayName: "push", repoDisplayName: "graftty",
            displayBranch: "push", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: .leaf(sessionName: "session", title: "Verify push delivery", attentionText: nil, isBusy: false, attentionSource: nil),
            sidebar: .init(id: "push", projectID: "project", unseenAgentStop: stop, agentProgressTimes: progressTimes))
    }
}
#endif
