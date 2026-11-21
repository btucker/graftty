import Foundation
import GrafttyKit
import Testing
@testable import GrafttyCLI

struct AntigravityHookTests {
    @Test("@spec AGENT-6.167: When Antigravity sends a lifecycle hook, the application shall use its conversation ID, treat only the first model invocation as a turn start, and keep the worktree busy until Antigravity reports that its background work has finished.")
    func readsNativeLifecycle() throws {
        let sessionID = UUID().uuidString
        let start = try #require(AntigravityHook(event: .sessionStart, payload: ["conversationId": sessionID]))
        #expect(start.sessionID == sessionID)
        let payload: [String: Any] = ["conversationId": sessionID, "lastUserInput": "Continue", "invocationNum": 0]
        #expect(AntigravityHook(event: .userPromptSubmit, payload: payload)?.prompt == "Continue")
        var later = payload
        later["invocationNum"] = 1
        #expect(AntigravityHook(event: .userPromptSubmit, payload: later) == nil)
        let stop: [String: Any] = ["conversationId": sessionID, "executionNum": 3, "fullyIdle": false]
        let background = try #require(AntigravityHook(event: .stop, payload: stop))
        #expect(background.turnID == "execution:3")
        #expect(!background.fullyIdle)
        var finished = stop
        finished["fullyIdle"] = true
        #expect(AntigravityHook(event: .stop, payload: finished)?.fullyIdle == true)
        #expect(AntigravityHook(event: .stop, payload: ["conversationId": sessionID]) == nil)
    }

    @Test("@spec AGENT-6.168: When Graftty returns context to Antigravity, the application shall use Antigravity's native hook output and allow Stop to complete without asking Antigravity to start another turn.")
    func emitsNativeContext() throws {
        let output = try TeamHookRenderer.sessionStart(runtime: .antigravity, instructions: "Worktree instructions.")
        let native = AntigravityHook.output(output, event: .sessionStart)
        let data = try #require(JSONSerialization.jsonObject(with: Data(native.utf8)) as? [String: Any])
        let steps = try #require(data["injectSteps"] as? [[String: String]])
        #expect(steps.first?["ephemeralMessage"]?.contains("Worktree instructions.") == true)
        #expect(data["hookSpecificOutput"] == nil)
        #expect(AntigravityHook.output(TeamHookRenderer.requestRecap(), event: .stop) == #"{"decision":"allow"}"#)
    }
}
