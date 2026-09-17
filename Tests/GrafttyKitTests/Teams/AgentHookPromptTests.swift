import Foundation
import Testing
@testable import GrafttyKit

struct AgentHookPromptTests {
    @Test("@spec AGENT-6.33: When a provider reports UserPromptSubmit, the application shall forward a bounded nonempty user prompt through the shared hook message for worktree artwork without capturing tool input or requiring new plugin hooks.")
    func forwardsOnlySubmittedUserPrompts() throws {
        #expect(AgentHookPrompt.text(event: .userPromptSubmit, payload: ["prompt": "Build a calendar"]) == "Build a calendar")
        #expect(AgentHookPrompt.text(event: .preToolUse, payload: ["prompt": "tool input"]) == nil)
        #expect(AgentHookPrompt.text(event: .userPromptSubmit, payload: ["prompt": "   "]) == nil)
        #expect(AgentHookPrompt.text(event: .userPromptSubmit, payload: ["prompt": 42]) == nil)
        #expect(AgentHookPrompt.text(event: .userPromptSubmit, payload: ["prompt": String(repeating: "a", count: 9000)])?.count == 4000)
        let message = NotificationMessage.teamHook(callerWorktree: "/repo/task", runtime: .codex,
            event: .userPromptSubmit, sessionID: "session", paneSessionName: "pane", userPrompt: "Build a calendar")
        let encoded = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: encoded) == message)
        let legacy = Data(#"{"type":"team_hook","caller_worktree":"/repo/task","runtime":"claude","event":"stop"}"#.utf8)
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: legacy)
        guard case .teamHook(_, _, _, _, _, _, _, _, let prompt) = decoded else {
            Issue.record("Expected hook message")
            return
        }
        #expect(prompt == nil)
    }
}
