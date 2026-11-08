import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct AttentionAskCardTests {
    private func worktree(stop: SidebarAgentStop?, layout: PaneLayoutNode? = nil) -> WorktreePanes {
        .init(path: "/wt", displayName: "task", repoDisplayName: "app", displayBranch: "task", state: .running,
              isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout,
              sidebar: .init(id: "/wt", projectID: "p", paneIDs: ["pane-1": "slot"], unseenAgentStop: stop, lastAgentStop: stop))
    }

    private func stop(need: String?, catchUp: String? = nil) -> SidebarAgentStop {
        var recap = AttentionRecap(title: "Compliance", completed: "Patched the ordering", next: "Rerun", need: need)
        recap.catchUp = catchUp
        return .init(agentName: "Claude", stoppedAt: Date(timeIntervalSinceReferenceDate: 100), recap: recap,
                     paneSlotID: "slot", providerSessionKey: "agent")
    }

    @Test("@spec AGENT-3.39: When an agent reports a need with a catch-up, the application shall retain the catch-up, limited to 600 characters, while decoding older recaps without one.")
    func recapCarriesAnOptionalCatchUp() throws {
        var recap = AttentionRecap(title: "T", completed: "C", next: "N", need: "Which?")
        recap.catchUp = String(repeating: "a", count: 600)
        #expect(recap.isValid)
        recap.catchUp = String(repeating: "a", count: 601)
        #expect(!recap.isValid)
        let old = try JSONDecoder().decode(AttentionRecap.self, from: Data(#"{"title":"T","completed":"C","next":"N"}"#.utf8))
        #expect(old.catchUp == nil)
        let new = try JSONDecoder().decode(AttentionRecap.self,
            from: Data(#"{"title":"T","completed":"C","next":"N","need":"Q?","catchUp":"Where things stand."}"#.utf8))
        #expect(new.catchUp == "Where things stand.")
    }

    @Test("@spec IOS-13.20: While a worktree's agent has stopped with a question, its ask card shall show the question, the agent's catch-up or else what it last completed, and Explain more shall send the catch-up prompt to that agent's pane before opening it.")
    func stoppedQuestionSendsThePrompt() throws {
        let navigation = SidebarNavigationState(prefix: "ask-card.\(UUID())")
        let asked = worktree(stop: stop(need: "Build and run, or rethink?", catchUp: "The suite gates 2.0."),
                             layout: .leaf(sessionName: "pane-1", title: "claude", attentionText: nil, isBusy: false, attentionSource: nil))
        let card = try #require(AttentionAskCard(context: navigation.worktreeContext(asked)))
        #expect(card.question == "Build and run, or rethink?")
        #expect(card.catchUp == "The suite gates 2.0.")
        #expect(card.agentName == "Claude")
        #expect(card.explain == .sendPrompt(paneID: "pane-1"))

        let bare = worktree(stop: stop(need: "Which one?"),
                            layout: .leaf(sessionName: "pane-1", title: "claude", attentionText: nil, isBusy: false, attentionSource: nil))
        let fallback = try #require(AttentionAskCard(context: navigation.worktreeContext(bare)))
        #expect(fallback.catchUp == nil)
        #expect(fallback.lastCompleted == "Patched the ordering")

        #expect(AttentionAskCard(context: navigation.worktreeContext(worktree(stop: stop(need: nil)))) == nil)
    }

    @Test("@spec IOS-13.21: While an agent waits at its harness's own prompt rather than a stopped turn, its ask card's Explain more shall open the pane without typing into it.")
    func harnessPromptOnlyOpens() throws {
        let navigation = SidebarNavigationState(prefix: "ask-card.\(UUID())")
        let waiting = worktree(stop: nil, layout: .leaf(sessionName: "pane-1", title: "claude",
            attentionText: "Claude needs your permission", isBusy: false, attentionSource: .agentStop))
        let card = try #require(AttentionAskCard(context: navigation.worktreeContext(waiting)))
        #expect(card.question == "Claude needs your permission")
        #expect(card.explain == .openOnly)
    }
}
