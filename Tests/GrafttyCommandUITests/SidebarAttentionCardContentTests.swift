import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

struct SidebarAttentionCardContentTests {
    @Test("@spec LAYOUT-2.73: When an agent recap is expanded in Attention, the card shall show the worktree heading, any gray pane title, and task context, any user question, and the next step in that order.")
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

    @MainActor
    @Test("@spec LAYOUT-2.79: While Attention cards are displayed, the application shall expand stopped reports regardless of viewing or selection and collapse resumed agents into Running rows.")
    func collapsesOnlyAfterResume() {
        let navigation = SidebarNavigationState(prefix: "presentation-\(UUID())")
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Task", context: "Context", completed: "Done", next: "Next", need: "Which device?"))
        var item = SidebarActivityItem(id: "stop", projectID: "p", worktreeID: "wt", paneID: nil,
            projectName: "graftty", worktreeName: "wt", title: stop.title,
            occurrence: stop.occurrence, isBusy: false, agentStop: stop)
        let list = SidebarAttentionList(navigation: navigation, items: [item], projects: [], onOpen: { _ in true })
        #expect(list.rowStyle(for: item) == .expanded)
        navigation.opened(item)
        #expect(list.rowStyle(for: item) == .expanded)
        item.isBusy = true
        #expect(list.rowStyle(for: item) == .running)
        item.isBusy = false
        #expect(list.rowStyle(for: item) == .expanded)
    }
}
