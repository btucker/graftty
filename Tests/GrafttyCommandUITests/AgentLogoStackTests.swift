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

    @Test("@spec LAYOUT-2.254: While a worktree has two or more agents, the application shall show one provider logo per agent beneath its sidebar icon, at most five followed by a count, ring a logo in orange while its agent asks for user input and in pulsing blue while it works, dim finished agents, and draw a ringed logo above its neighbours with the asking one on top.")
    func stackContents() {
        #expect(AgentLogoStackModel.visible([logo("a")]).shown.isEmpty)
        let two = AgentLogoStackModel.visible([logo("a"), logo("b")])
        #expect(two.shown.map(\.id) == ["a", "b"] && two.overflow == 0)
        let seven = AgentLogoStackModel.visible((1...7).map { logo("\($0)") })
        #expect(seven.shown.count == 5 && seven.overflow == 2)
        #expect(AgentLogoStackModel.zOrder(logo("ask", dot: .asking)) > AgentLogoStackModel.zOrder(logo("work", dot: .working)))
        #expect(AgentLogoStackModel.zOrder(logo("work", dot: .working)) > AgentLogoStackModel.zOrder(logo("idle")))
        #expect(logo("done", finished: true).status.isDimmed)
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
}
