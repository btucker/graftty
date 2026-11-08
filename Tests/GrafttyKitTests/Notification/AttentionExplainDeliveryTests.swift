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

    @Test func requestRoundTripsOnTheWire() throws {
        let request = WorktreeManagementRequest.explainRequest(worktreeID: "/repo", paneID: "pane-1")
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"explain_request\""))
        #expect(try JSONDecoder().decode(WorktreeManagementRequest.self, from: data) == request)
    }
}
