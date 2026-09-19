import Foundation
import Testing
@testable import GrafttyKit

struct AgentHookPromptTests {
    @Test("@spec AGENT-6.33: When a provider reports UserPromptSubmit, the application shall forward a bounded nonempty user prompt through the shared hook message for worktree artwork, excluding native subagent prompts, injected instructions, and tool input without requiring new plugin hooks.")
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

    @Test func excludesSubagentsAndInjectedMessagesBeforeTruncation() {
        #expect(AgentHookPrompt.text(event: .userPromptSubmit,
            payload: ["agent_id": "child", "prompt": "Review the repository"]) == nil)
        for injected in [
            "# AGENTS.md instructions for /repo\n<INSTRUCTIONS>private rules</INSTRUCTIONS>",
            "<environment_context>private paths</environment_context>",
            "Graftty reply: command\n<graftty-peer-message>peer task</graftty-peer-message>",
            "<graftty-system-message>internal notice</graftty-system-message>",
            String(repeating: "x", count: 4500) + "<graftty-forge-message>forge event</graftty-forge-message>",
        ] {
            #expect(AgentHookPrompt.text(event: .userPromptSubmit, payload: ["prompt": injected]) == nil)
        }
        #expect(AgentHookPrompt.text(event: .userPromptSubmit,
            payload: ["prompt": "<system-reminder>private instructions</system-reminder>Build a calendar"])
            == "Build a calendar")
    }
}
