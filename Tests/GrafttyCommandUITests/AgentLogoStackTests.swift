import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyCommandUI

struct AgentLogoStackTests {
    private func logo(_ id: String, dot: AgentTileDot? = nil, finished: Bool = false) -> AgentLogo {
        AgentLogo(id: id, session: id, provider: "claude", title: id,
                  status: AgentTileStatus(needsInput: dot == .asking, isBusy: dot == .working, isCompleted: finished,
                                          isCached: false, question: nil, result: nil, statusLabel: "Running"))
    }

    @Test("@spec LAYOUT-2.254: While a worktree has two or more agents that have not finished, the application shall show one provider logo per such agent beneath its sidebar icon, at most five followed by a count, leave finished agents out, ring a logo in orange while its agent asks for user input and in pulsing blue while it works, and draw a ringed logo above its neighbours with the asking one on top.")
    func stackContents() {
        #expect(AgentLogoStackModel.visible([logo("a")]).shown.isEmpty)
        let two = AgentLogoStackModel.visible([logo("a"), logo("b")])
        #expect(two.shown.map(\.id) == ["a", "b"] && two.overflow == 0)
        let seven = AgentLogoStackModel.visible((1...7).map { logo("\($0)") })
        #expect(seven.shown.count == 5 && seven.overflow == 2)
        #expect(AgentLogoStackModel.zOrder(logo("ask", dot: .asking)) > AgentLogoStackModel.zOrder(logo("work", dot: .working)))
        #expect(AgentLogoStackModel.zOrder(logo("work", dot: .working)) > AgentLogoStackModel.zOrder(logo("idle")))
        #expect(AgentLogoStackModel.visible([logo("a"), logo("b"), logo("done", finished: true)]).shown.map(\.id) == ["a", "b"])
        #expect(AgentLogoStackModel.visible([logo("a"), logo("done", finished: true)]).shown.isEmpty)
    }

    @Test func logosComeFromTheWorktreesAgents() {
        let agents = [
            AgentSessionInfo(id: "lead", name: "Lead", provider: "claude", status: "running", sessionName: "s1"),
            AgentSessionInfo(id: "review", name: "Review", provider: "codex", status: "running", sessionName: "s2"),
            AgentSessionInfo(id: "gone", name: "Gone", provider: "codex", status: "closed", sessionName: nil),
        ]
        let layout: PaneLayoutNode = .split(direction: .horizontal, ratio: 0.5,
            left: .leaf(sessionName: "s1", title: "Fix the rail", attentionText: nil, isBusy: true, attentionSource: nil),
            right: .leaf(sessionName: "s2", title: "", attentionText: nil, isBusy: false, attentionSource: nil))
        let worktree = WorktreePanes(path: "/repo/wt", displayName: "wt", repoDisplayName: "app", displayBranch: "wt",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout,
            agents: agents)
        let logos = AgentLogo.logos(in: SidebarWorktreeContext(worktree: worktree), isCached: false)
        #expect(logos.map(\.id) == ["lead", "review"])
        #expect(logos.map(\.session) == ["s1", "s2"])
        #expect(logos.map(\.title) == ["Fix the rail", "Review"])
        #expect(logos.map(\.status.dot) == [.working, nil])
    }

    private func twoAgentWorktree(leadBusy: Bool, reviewBusy: Bool, sidebar: SidebarWorktreeMetadata?,
                                  extraAgents: [AgentSessionInfo] = []) -> WorktreePanes {
        let layout: PaneLayoutNode = .split(direction: .horizontal, ratio: 0.5,
            left: .leaf(sessionName: "s1", title: "Lead", attentionText: nil, isBusy: leadBusy, attentionSource: nil),
            right: .leaf(sessionName: "s2", title: "Review", attentionText: nil, isBusy: reviewBusy, attentionSource: nil))
        return WorktreePanes(path: "/repo/wt", displayName: "wt", repoDisplayName: "app", displayBranch: "wt",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout,
            sidebar: sidebar,
            agents: [AgentSessionInfo(id: "lead", name: "Lead", provider: "claude", status: "running", sessionName: "s1"),
                     AgentSessionInfo(id: "review", name: "Review", provider: "codex", status: "running", sessionName: "s2")]
                + extraAgents)
    }

    @Test func anotherAgentsUnreadStopLeavesAWorkingLogoRinged() {
        let stop = SidebarAgentStop(agentName: "Lead", stoppedAt: Date(timeIntervalSinceReferenceDate: 100),
            recap: .init(title: "Done", completed: "Rail", next: "Review", need: nil), paneSlotID: "slot-1")
        let worktree = twoAgentWorktree(leadBusy: true, reviewBusy: true,
            sidebar: .init(id: "stable", projectID: "p", paneIDs: ["s1": "slot-1", "s2": "slot-2"], unseenAgentStop: stop))
        let context = SidebarWorktreeContext(worktree: worktree)
        #expect(context.hasUnseenStop)
        // The stopped agent's own liveness may lag its stop; the other agent is still working.
        #expect(AgentLogo.logos(in: context, isCached: false).map(\.status.dot) == [nil, .working])
    }

    @Test func openingALogoRoutesToItsPane() {
        let done = AgentSessionInfo(id: "done", name: "Done", provider: "codex", status: "closed",
                                    sessionName: nil, retainedSessionName: "s3")
        // A host that publishes pane ids routes a pane by them, not by its session name.
        for sidebar: SidebarWorktreeMetadata? in [.init(id: "stable", projectID: "p", paneIDs: ["s1": "slot-1", "s2": "slot-2"]), nil] {
            let worktree = twoAgentWorktree(leadBusy: false, reviewBusy: false, sidebar: sidebar, extraAgents: [done])
            let logos = AgentLogo.logos(in: SidebarWorktreeContext(worktree: worktree), isCached: false)
            for logo in logos where logo.id != "done" {
                #expect(SidebarProjection.attentionPaneRoute(for: logo.activityItem(in: worktree), in: worktree) == logo.session)
            }
            // A finished agent has no live pane, so its logo opens the worktree instead of a missing pane.
            let finished = logos.first { $0.id == "done" }
            #expect(finished?.activityItem(in: worktree).paneID == nil)
        }
    }
}
