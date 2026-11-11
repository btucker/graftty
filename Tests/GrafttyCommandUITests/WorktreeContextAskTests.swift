import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct WorktreeContextAskTests {
    private let pane = PaneLayoutNode.leaf(sessionName: "pane-1", title: "claude", attentionText: nil, isBusy: false, attentionSource: nil)

    private func worktree(stop: SidebarAgentStop?, layout: PaneLayoutNode? = nil) -> WorktreePanes {
        .init(path: "/wt", displayName: "task", repoDisplayName: "app", displayBranch: "task", state: .running,
              isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout ?? pane,
              sidebar: .init(id: "/wt", projectID: "p", paneIDs: ["pane-1": "slot"], unseenAgentStop: stop, lastAgentStop: stop))
    }

    private func stop(_ options: [AttentionRecap.Option]?, catchUp: String? = "0.8.0 carries the sidebar fix.") -> SidebarAgentStop {
        var recap = AttentionRecap(title: "Release", completed: "Found the crash.", next: "Decide.", need: "Hold or ship?")
        recap.options = options
        recap.catchUp = catchUp
        return .init(agentName: "Claude", stoppedAt: Date(timeIntervalSinceReferenceDate: 100), recap: recap,
                     paneSlotID: "slot", providerSessionKey: "agent")
    }

    private func context(_ worktree: WorktreePanes) -> SidebarWorktreeContext {
        SidebarNavigationState(prefix: "context-ask.\(UUID())").worktreeContext(worktree)
    }

    private let options: [AttentionRecap.Option] = [.init(label: "Hold", cost: "Sidebar fix waits", suggested: true),
                                                     .init(label: "Ship", cost: "Older macOS may crash")]

    @Test("@spec CONTEXT-61: While an agent has stopped with a question, Context on Mac and mobile shall end with the question under a Waiting for you label, one row per reported option showing its cost and marking the suggested one, a Why this is being asked disclosure for the catch-up, and a reply field, and shall offer only Answer in the agent's terminal for a prompt the harness owns or when the host cannot be answered from here.")
    func affordancesFollowTheKindOfQuestion() throws {
        let stopped = WorktreeContextAsk.Affordances(context(worktree(stop: stop(options))), canSend: true)
        #expect(stopped.question == "Hold or ship?")
        #expect(stopped.options.map(\.label) == ["Hold", "Ship"])
        #expect(stopped.options.first?.suggested == true)
        #expect(stopped.catchUp == "0.8.0 carries the sidebar fix.")
        #expect(stopped.showsReply)
        #expect(!stopped.answerInTerminal)
        let target = try #require(stopped.target)
        #expect(target.paneID == "pane-1")
        #expect(target.occurrence == stop(options).occurrence)

        let open = WorktreeContextAsk.Affordances(context(worktree(stop: stop(nil))), canSend: true)
        #expect(open.options.isEmpty)
        #expect(open.showsReply, "A question without options still takes a typed reply")

        let harness = WorktreeContextAsk.Affordances(context(worktree(stop: nil, layout: .leaf(sessionName: "pane-1", title: "claude",
            attentionText: "Claude needs your permission", isBusy: false, attentionSource: .agentStop))), canSend: true)
        #expect(harness.question == "Claude needs your permission")
        #expect(harness.options.isEmpty)
        #expect(!harness.showsReply)
        #expect(harness.answerInTerminal)

        let readOnly = WorktreeContextAsk.Affordances(context(worktree(stop: stop(options))), canSend: false)
        #expect(readOnly.options.map(\.label) == ["Hold", "Ship"], "Options still explain the choice")
        #expect(!readOnly.showsReply)
        #expect(readOnly.answerInTerminal)
    }

    @Test("@spec CONTEXT-62: When the user picks an option or sends a reply in Context, the application shall send it to the asking agent, disable the question while sending, show Sent until the question changes, and show the host's message and re-enable on failure.")
    func sendingMovesThroughSentAndFailed() async throws {
        let affordances = WorktreeContextAsk.Affordances(context(worktree(stop: stop(options))), canSend: true)
        let target = try #require(affordances.target)
        let model = WorktreeContextAskModel()
        model.sync(target)
        var sent: [AttentionAnswer] = []
        var reply: String? = nil
        let send: @MainActor (AttentionAnswer) async -> String? = { answer in
            sent.append(answer)
            #expect(model.state == .sending, "The question is disabled while sending")
            return reply
        }

        await model.send("Hold", using: send)
        #expect(sent.map(\.text) == ["Hold"])
        #expect(sent.first?.paneID == "pane-1")
        #expect(model.state == .sent)
        await model.send("Ship", using: send)
        #expect(sent.count == 1, "A sent question takes no second answer")

        var later = target
        later.occurrence.text = "A newer question?"
        model.sync(later)
        #expect(model.state == .idle, "A new question can be answered again")

        reply = "This request has changed or already cleared."
        await model.send("Ship", using: send)
        #expect(model.state == .failed("This request has changed or already cleared."))
        reply = nil
        await model.send("Ship", using: send)
        #expect(model.state == .sent, "A failure re-enables the question")

        model.sync(target)
        await model.send("   ", using: send)
        #expect(model.state == .idle, "An empty reply is not sent")
    }

    @Test func hostResponsesBecomeMessages() {
        #expect(AttentionAnswer.failureMessage(for: .ok) == nil)
        #expect(AttentionAnswer.failureMessage(for: .error(code: "malformed-request", message: "x", forceAllowed: false, shortStatus: nil))
            == "Update Graftty on this Mac to answer from here.")
        #expect(AttentionAnswer.failureMessage(for: .error(code: "occurrence-changed", message: "This request has changed or already cleared.",
            forceAllowed: false, shortStatus: nil)) == "This request has changed or already cleared.")
        #expect(AttentionAnswer.failureMessage(for: .icon(nil)) == "The host couldn't deliver this answer.")
    }
}
