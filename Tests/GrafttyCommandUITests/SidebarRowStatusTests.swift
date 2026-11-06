import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@Suite("@spec LAYOUT-2.222: While the sidebar displays a worktree, the application shall show at most one status line, choosing in order an agent question, notification text, a working agent, the where-we-are text, or nothing.")
struct SidebarRowStatusTests {
    private func leaf(_ name: String, busy: Bool = false, attention: String? = nil, source: AttentionSource? = nil) -> PaneLayoutNode {
        .leaf(sessionName: name, title: "\(name) title", attentionText: attention, isBusy: busy, attentionSource: source)
    }
    private func worktree(layout: PaneLayoutNode? = nil, attention: String? = nil, source: AttentionSource? = nil,
                          stop: SidebarAgentStop? = nil, last: SidebarAgentStop? = nil, brief: WorktreeBrief? = nil) -> WorktreePanes {
        WorktreePanes(path: "/w", displayName: "w", repoDisplayName: "app", displayBranch: "w", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: attention, attentionSource: source, attentionTimestamp: attention == nil ? nil : Date(timeIntervalSince1970: 5), layout: layout,
            sidebar: .init(id: "s", projectID: "p", unseenAgentStop: stop, lastAgentStop: last, brief: brief))
    }
    private var brief: WorktreeBrief {
        WorktreeBrief(recap: AttentionRecap(title: "t", completed: "Tests pass.", next: "n"), at: Date(timeIntervalSince1970: 1))
    }
    private func status(_ row: WorktreePanes, asleep: Bool = false) -> SidebarRowStatus {
        SidebarRowStatus.resolve(context: SidebarWorktreeContext(worktree: row), worktree: row, isAsleep: asleep)
    }

    @Test func onlyAQuestionOrPaneNotificationOpensAPane() {
        #expect(SidebarRowStatus.question("q", paneID: nil).opensPane)
        #expect(SidebarRowStatus.notification("n", paneID: "p").opensPane)
        #expect(!SidebarRowStatus.notification("n", paneID: nil).opensPane)
        #expect(!SidebarRowStatus.working("w").opensPane)
        #expect(!SidebarRowStatus.whereWeAre("w", isUnread: true).opensPane)
    }

    @Test("@spec LAYOUT-2.208: While a worktree row's status line asks for input, the application shall show that line on a soft tint in the attention color and shall show no hand on the row, because the color already says so.")
    func onlyAQuestionOrNotificationNeedsAttention() {
        #expect(SidebarRowStatus.question("q", paneID: nil).needsAttention)
        #expect(SidebarRowStatus.notification("n", paneID: nil).needsAttention)
        #expect(!SidebarRowStatus.whereWeAre("w", isUnread: true).needsAttention)
        #expect(!SidebarRowStatus.working("w").needsAttention)
        #expect(!SidebarRowStatus.none.needsAttention)
    }

    @Test("@spec LAYOUT-2.211: While a worktree row shows its emoji, the application shall draw it at full strength while the worktree asks for input or works, and fade it otherwise.")
    func identityFadesWhenNothingIsHappening() {
        for live in [SidebarRowStatus.question("q", paneID: nil), .notification("n", paneID: nil), .working("w")] {
            #expect(live.identityOpacity(isDark: true) == 1)
            #expect(live.identityOpacity(isDark: false) == 1)
        }
        for idle in [SidebarRowStatus.whereWeAre("w", isUnread: true), .whereWeAre("w", isUnread: false), .none] {
            #expect(idle.identityOpacity(isDark: true) < 1)
            #expect(idle.identityOpacity(isDark: false) < 1)
        }
    }

    @Test func questionBeatsNotification() {
        let row = worktree(layout: leaf("a", attention: "Which image?", source: .agentStop), attention: "Build done", source: .userNotify)
        guard case .question("Which image?", "a") = status(row) else { Issue.record("\(status(row))"); return }
    }
    @Test("@spec STATE-2.3: While a worktree has notification text, the sidebar shall show it in the status line of that worktree, ahead of a working agent, regardless of the worktree running state.")
    func notificationBeatsWorking() {
        let row = worktree(layout: leaf("a", busy: true), attention: "Build done", source: .userNotify)
        guard case .notification("Build done", nil) = status(row) else { Issue.record("\(status(row))"); return }
    }
    @Test func workingBeatsWhereWeAre() {
        guard case .working("a title") = status(worktree(layout: leaf("a", busy: true), brief: brief)) else { Issue.record("wrong"); return }
    }
    @Test func oneAgentShowsItsTitle() {
        guard case .working("a title") = status(worktree(layout: leaf("a", busy: true))) else { Issue.record("wrong"); return }
    }
    @Test func twoAgentsShowCount() {
        let row = worktree(layout: .split(direction: .horizontal, ratio: 0.5, left: leaf("a", busy: true), right: leaf("b", busy: true)))
        guard case .working("2 agents working") = status(row) else { Issue.record("\(status(row))"); return }
    }
    @Test func idleAgentShowsWhereWeAre() {
        guard case .whereWeAre("Tests pass.", isUnread: false) = status(worktree(layout: leaf("a"), brief: brief)) else { Issue.record("wrong"); return }
    }
    @Test func unreadStopIsMarkedUnread() {
        let stop = SidebarAgentStop(agentName: "Claude", stoppedAt: Date(timeIntervalSince1970: 3))
        guard case .whereWeAre("Tests pass.", isUnread: true) = status(worktree(stop: stop, brief: brief)) else { Issue.record("wrong"); return }
    }
    @Test func noBriefGivesNone() {
        guard case .none = status(worktree()) else { Issue.record("wrong"); return }
    }
    @Test func asleepShowsCachedBriefOnly() {
        let row = worktree(layout: leaf("a", busy: true), attention: "Build done", source: .userNotify, brief: brief)
        guard case .whereWeAre("Tests pass.", isUnread: false) = status(row, asleep: true) else { Issue.record("\(status(row, asleep: true))"); return }
    }
}
