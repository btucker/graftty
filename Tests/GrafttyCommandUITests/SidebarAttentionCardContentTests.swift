import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

struct SidebarAttentionCardContentTests {
    @Test("@spec LAYOUT-2.73: When a stopped agent has a recap, the Attention card shall show the worktree name, a gray pane title beneath it, and Context, Needs You, Up Next in that order; if no question exists it shall omit Needs You.")
    func stoppedCardUsesChosenHierarchy() {
        let recap = AttentionRecap(
            title: "Paired-device push notifications",
            context: "Pairing devices so a release build can notify a locked phone.",
            completed: "Client integration and tests committed; no PR yet.",
            next: "Verify relay and APNs on devices, then open a PR.",
            need: "Does done mean merged code or a notification on a locked phone?"
        )
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
                                    recap: recap, paneTitle: "Summarize current progress")
        let item = SidebarActivityItem(
            id: "stop", projectID: "p", worktreeID: "/repo/push-notifications", paneID: nil,
            projectName: "graftty", worktreeName: "push-notifications", title: stop.title,
            occurrence: stop.occurrence, isBusy: false, agentStop: stop
        )

        let withIcon = SidebarAttentionCardContent(item: item)
        #expect(withIcon.headerName == "push-notifications")
        #expect(withIcon.paneTitle == "Summarize current progress")
        #expect(withIcon.title == "Paired-device push notifications")
        #expect(withIcon.sections.map(\.kind) == [.context, .needsYou, .upNext])
        #expect(withIcon.sections[0].text == recap.context)
        #expect(withIcon.sections[0].detail == recap.completed)
        #expect(withIcon.sections[1].text == recap.need)
        #expect(withIcon.sections[2].text == recap.next)
        #expect(SidebarAttentionCardContent(item: item).headerName == "push-notifications")

        let old = AttentionRecap(title: "Push notifications", completed: "Client committed.",
                                 next: "Verify on a device.")
        var noQuestion = item
        noQuestion.agentStop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now, recap: old)
        let fallback = SidebarAttentionCardContent(item: noQuestion)
        #expect(fallback.sections.map(\.kind) == [.context, .upNext])
        #expect(fallback.sections[0].text == old.completed)
        #expect(fallback.sections[0].detail == nil)
    }
}
