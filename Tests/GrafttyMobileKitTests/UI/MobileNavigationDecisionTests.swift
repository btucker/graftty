import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol
import GrafttyCommandUI

@Suite("@spec IOS-4.17: When the user selects a worktree from the picker (`IOS-4.1`) whose creation is not in progress and whose pane layout is a single leaf, the application shall push the fullscreen terminal for that pane directly onto the navigation stack, bypassing the worktree-detail screen (`IOS-4.10`). The system edge-swipe-back gesture and the in-app back button (`IOS-5.5`) shall return the user to the worktree picker.")
struct MobileNavigationDecisionTests {

    @Test
    func singleLeafLayoutDecidesToSession() {
        let layout: PaneLayoutNode = .leaf(
            sessionName: "abc",
            title: "Sass",
            attentionText: nil,
            isBusy: false,
            attentionSource: nil
        )
        #expect(
            MobileNavigationDecision.decide(layout: layout)
                == .session(sessionName: "abc", title: "Sass")
        )
    }

    @Test
    func singleLeafWithEmptyTitleCarriesTheEmptyTitle() {
        let layout: PaneLayoutNode = .leaf(
            sessionName: "abc",
            title: "",
            attentionText: nil,
            isBusy: false,
            attentionSource: nil
        )
        #expect(
            MobileNavigationDecision.decide(layout: layout)
                == .session(sessionName: "abc", title: "")
        )
    }

    @Test
    func splitLayoutDecidesToWorktreeDetail() {
        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "a", title: "A", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "b", title: "B", attentionText: nil, isBusy: false, attentionSource: nil)
        )
        #expect(MobileNavigationDecision.decide(layout: layout) == .worktreeDetail)
    }

    @Test
    func nilLayoutDecidesToWorktreeDetail() {
        #expect(MobileNavigationDecision.decide(layout: nil) == .worktreeDetail)
    }

    @Test("""
@spec IOS-4.21: When the user opens a pane from an attention request in the worktree picker (`IOS-4.1`), the application shall push the fullscreen terminal for that pane directly onto the navigation stack, bypassing the worktree detail screen.
""")
    func paneRowTapDecidesToSession() {
        let node: PaneLayoutNode = .leaf(sessionName: "abc", title: "Editor", attentionText: nil, isBusy: false, attentionSource: nil)
        let leaf = node.leaves[0]
        #expect(
            MobileNavigationDecision.decide(paneRow: leaf)
                == .session(sessionName: "abc", title: "Editor")
        )
    }
}

@MainActor
struct MobileWorktreeOpeningTests {
    private func row(agents: [AgentSessionInfo]?, layout: PaneLayoutNode?, stop: SidebarAgentStop? = nil) -> WorktreePanes {
        WorktreePanes(path: "/w", displayName: "w", repoDisplayName: "r", displayBranch: "w", state: .running, isMainCheckout: false,
            prBadge: nil, stats: nil, attentionText: nil, layout: layout, sidebar: .init(id: "w", projectID: "r", unseenAgentStop: stop), agents: agents)
    }
    private func leaf(_ name: String, busy: Bool = false, attention: String? = nil, source: AttentionSource? = nil) -> PaneLayoutNode {
        .leaf(sessionName: name, title: name, attentionText: attention, isBusy: busy, attentionSource: source)
    }
    private func split(_ a: PaneLayoutNode, _ b: PaneLayoutNode) -> PaneLayoutNode {
        .split(direction: .horizontal, ratio: 0.5, left: a, right: b)
    }
    private func agent(_ name: String) -> AgentSessionInfo {
        AgentSessionInfo(id: name, name: name, provider: "claude", status: "running", sessionName: name)
    }
    private func decide(_ row: WorktreePanes) -> MobileNavigationDecision {
        MobileNavigationDecision.decide(worktree: row, context: SidebarWorktreeContext(worktree: row))
    }

    @Test("@spec IOS-13.16: When the user taps a worktree with agents on iPhone, the application shall open the agent that most needs them, in the order asking, working, idle, failed, then finished, rather than a list of its agents.")
    func tapOpensTheAgentThatMostNeedsThePerson() {
        let idleFirst = row(agents: [agent("idle"), agent("busy")], layout: split(leaf("idle"), leaf("busy", busy: true)))
        guard case .session("busy", _) = decide(idleFirst) else { Issue.record("\(decide(idleFirst))"); return }
        let asking = row(agents: [agent("busy"), agent("ask")],
            layout: split(leaf("busy", busy: true), leaf("ask", attention: "Merge?", source: .agentStop)))
        guard case .session("ask", _) = decide(asking) else { Issue.record("\(decide(asking))"); return }
    }

    @Test func worktreeWithoutAgentsKeepsItsPaneRoute() {
        guard case .session("shell", _) = decide(row(agents: [], layout: leaf("shell"))) else { Issue.record("single pane"); return }
        #expect(decide(row(agents: [], layout: split(leaf("a"), leaf("b")))) == .worktreeDetail)
        #expect(decide(row(agents: nil, layout: nil)) == .worktreeDetail)
    }

    #if canImport(UIKit)
    @Test("@spec IOS-13.17: While a terminal is open, the application shall name its worktree and host under the agent's name, because nothing else on that screen says where it is.")
    func pillNamesWorktreeAndHost() {
        #expect(CompactAgentBar.location(worktree: row(agents: nil, layout: nil), hostLabel: "mini") == "w · mini")
        #expect(CompactAgentBar.location(worktree: row(agents: nil, layout: nil), hostLabel: nil) == "w")
    }
    #endif
}
