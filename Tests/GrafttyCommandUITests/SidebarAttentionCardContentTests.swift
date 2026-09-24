import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

struct SidebarAttentionCardContentTests {
    @Test("@spec LAYOUT-2.73: When an agent recap is expanded in Attention, the card shall show the worktree name, a gray pane title beneath it, and task context, any user question, and the next step in that order.")
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

    @Test("@spec LAYOUT-2.79: While Needs You contains agent stops and other requests, the application shall group explicit recap questions first, keep stops without questions visible in compact rows, and retain other requests.")
    func groupsQuestionsAndRoutineStops() {
        func item(_ id: String, need: String? = nil, stopped: Bool = true) -> SidebarActivityItem {
            let stop = stopped ? SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
                recap: .init(title: id, context: "Context", completed: "Done", next: "Next", need: need)) : nil
            return SidebarActivityItem(id: id, projectID: "p", worktreeID: id, paneID: nil,
                projectName: "graftty", worktreeName: id, title: id,
                occurrence: .init(timestamp: .now, text: id, source: stopped ? .agentStop : .userNotify),
                isBusy: false, agentStop: stop)
        }
        let buckets = SidebarAttentionBuckets(items: [
            item("routine-1"), item("question-1", need: "Which device?"),
            item("notify", stopped: false), item("question-2", need: "Which build?"), item("routine-2")
        ])
        #expect(buckets.questions.map(\.id) == ["question-1", "question-2"])
        #expect(buckets.stopped.map(\.id) == ["routine-1", "routine-2"])
        #expect(buckets.other.map(\.id) == ["notify"])
    }
}
