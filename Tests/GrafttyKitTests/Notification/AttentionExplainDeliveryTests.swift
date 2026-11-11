import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
struct AttentionExplainDeliveryTests {
    @Test("@spec AGENT-3.40: When a client asks a host to explain a stopped agent's question, the host shall type the catch-up prompt into that agent's pane and submit it, and shall refuse a pane it cannot find or one waiting at its harness's own prompt.")
    func typesTheCatchUpPromptIntoTheAskingPane() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let first = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        let second = PaneSlotID()
        var worktree = platform.state.repos[0].worktrees[0]
        worktree.splitTree = worktree.splitTree.inserting(second, at: first, direction: .horizontal)
        worktree.ensurePaneSession(for: second)
        platform.state.repos[0].worktrees[0] = worktree
        let session = ZmxLauncher.sessionName(for: try #require(worktree.paneSessions[second]))

        let response = await AttentionExplainDelivery.deliver(worktreeID: "/repo", paneID: session, platform: platform)
        #expect(response == .ok)
        #expect(platform.platformRequests == [.sendPane(path: "/repo", index: 2, text: AttentionExplainPrompt.text, pressEnter: true)])

        let missing = await AttentionExplainDelivery.deliver(worktreeID: "/repo", paneID: "gone", platform: platform)
        guard case .error = missing else { Issue.record("expected an error, got \(missing)"); return }
        #expect(platform.platformRequests.count == 1)

        // A stale card must not type into a permission or question prompt: Enter would answer it.
        platform.state.repos[0].worktrees[0].paneAttention[second] = Attention(
            text: "Claude needs your permission", timestamp: Date(), source: .agentStop)
        let prompting = await AttentionExplainDelivery.deliver(worktreeID: "/repo", paneID: session, platform: platform)
        guard case .error = prompting else { Issue.record("expected an error, got \(prompting)"); return }
        #expect(platform.platformRequests.count == 1)
    }

    @Test("@spec AGENT-3.50: When a client answers a stopped agent's question, the host shall type the answer as one line without control characters into that agent's pane and submit it, and shall refuse when the question has changed or cleared, the answer is empty, the pane is gone or belongs to another agent or shell, or the pane is waiting at its harness's own prompt.")
    func typesTheAnswerIntoTheAskingPane() async throws {
        let platform = try ControlRequestCoreTests.RecordingPlatform()
        let slot = try #require(platform.state.repos[0].worktrees[0].splitTree.allLeaves.first)
        platform.state.repos[0].worktrees[0].ensurePaneSession(for: slot)
        let session = ZmxLauncher.sessionName(for: try #require(platform.state.repos[0].worktrees[0].paneSessions[slot]))
        let stop = SidebarAgentStop(agentName: "Claude", stoppedAt: Date(timeIntervalSinceReferenceDate: 500),
            recap: AttentionRecap(title: "Release", completed: "Found it.", next: "Decide.", need: "Hold or ship?"),
            paneSlotID: slot.id.uuidString, providerSessionKey: "agent")
        platform.state.repos[0].worktrees[0].unseenAgentStop = stop
        func answer(_ text: String, occurrence: SidebarAttentionOccurrence? = nil, pane: String? = nil) async -> WorktreeManagementResponse {
            await AttentionAnswerDelivery.deliver(worktreeID: "/repo", paneID: pane ?? session,
                occurrence: occurrence ?? stop.occurrence, text: text, platform: platform)
        }

        #expect(await answer("Hold") == .ok)
        #expect(await answer("Hold,\nthen ship\r\n") == .ok)
        // Tab, Escape and Ctrl-C would act on the agent's input rather than read as text.
        #expect(await answer("Hold\tthen\u{1B}ship\u{03} 👨‍👩‍👧") == .ok)
        #expect(platform.platformRequests == [
            .sendPane(path: "/repo", index: 1, text: "Hold", pressEnter: true),
            .sendPane(path: "/repo", index: 1, text: "Hold, then ship", pressEnter: true),
            .sendPane(path: "/repo", index: 1, text: "Hold then ship 👨‍👩‍👧", pressEnter: true),
        ])

        // Another pane in the worktree may be a shell: the answer goes only to the agent that asked.
        let shell = PaneSlotID()
        platform.state.repos[0].worktrees[0].splitTree = platform.state.repos[0].worktrees[0].splitTree
            .inserting(shell, at: slot, direction: .horizontal)
        platform.state.repos[0].worktrees[0].ensurePaneSession(for: shell)
        let shellSession = ZmxLauncher.sessionName(for: try #require(platform.state.repos[0].worktrees[0].paneSessions[shell]))
        guard case .error = await answer("rm -rf build", pane: shellSession) else {
            Issue.record("expected a refusal for a pane other than the asking agent's"); return
        }
        #expect(platform.platformRequests.count == 3)

        var stale = stop.occurrence
        stale.text = "An earlier question?"
        let changed = await answer("Hold", occurrence: stale)
        #expect(changed == .error(code: "occurrence-changed", message: "This request has changed or already cleared.",
                                  forceAllowed: false, shortStatus: nil))
        guard case .error = await answer("  \n "), case .error = await answer("Hold", pane: "gone") else {
            Issue.record("expected errors for an empty answer and a missing pane"); return
        }
        platform.state.repos[0].worktrees[0].paneAttention[slot] = Attention(
            text: "Claude needs your permission", timestamp: Date(), source: .agentStop)
        guard case .error = await answer("Hold") else { Issue.record("expected a harness-prompt refusal"); return }
        platform.state.repos[0].worktrees[0].paneAttention[slot] = nil
        platform.state.repos[0].worktrees[0].unseenAgentStop = nil
        #expect(await answer("Hold") == changed, "A cleared question refuses as a changed one")
        #expect(platform.platformRequests.count == 3)
    }

    @Test func answerRequestRoundTripsOnTheWire() throws {
        let occurrence = SidebarAttentionOccurrence(timestamp: Date(timeIntervalSinceReferenceDate: 7), text: "Q?", source: .agentStop)
        let request = WorktreeManagementRequest.answerRequest(worktreeID: "/repo", paneID: "pane-1", occurrence: occurrence, text: "Hold")
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"answer_request\""))
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: data) == request)
    }

    @Test func requestRoundTripsOnTheWire() throws {
        let request = WorktreeManagementRequest.explainRequest(worktreeID: "/repo", paneID: "pane-1")
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"explain_request\""))
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: data) == request)
    }
}
