import Foundation
import GrafttyKit
import Testing
@testable import GrafttyCLI

struct AntigravityHookTests {
    @Test("@spec AGENT-6.167: When Antigravity sends a lifecycle hook, the application shall use its conversation ID, treat only the first model invocation as a turn start, and keep the worktree busy until Antigravity reports that its background work has finished.")
    func readsNativeLifecycle() throws {
        let sessionID = UUID().uuidString
        let start = try #require(AntigravityHook(event: .sessionStart, payload: [
            "conversationId": sessionID, "cwd": "/repo/wt", "workspacePaths": ["/repo"]
        ]))
        #expect(start.sessionID == sessionID)
        #expect(start.workingDirectory == "/repo/wt")
        let fallback = try #require(AntigravityHook(event: .sessionStart, payload: [
            "conversationId": sessionID, "cwd": "", "workspacePaths": ["/repo/fallback"]
        ]))
        #expect(fallback.workingDirectory == "/repo/fallback")
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

    @Suite("@spec AGENT-6.179: When Antigravity starts a turn that no new user input began, such as a turn woken by a delivered team message, the application shall treat it as a turn start without recording the previous user prompt again.")
    struct TurnOrigin {
        private let sessionID = UUID().uuidString

        @Test func recordsThePromptOfATurnTheUserStarted() throws {
            let hook = try turnStart(steps: ["USER_INPUT", "PLANNER_RESPONSE", "USER_INPUT"], initialNumSteps: 3)
            #expect(hook.prompt == "Continue")
        }

        @Test func recordsNoPromptForATurnADeliveredMessageStarted() throws {
            let hook = try turnStart(steps: ["USER_INPUT", "SYSTEM_MESSAGE", "PLANNER_RESPONSE"], initialNumSteps: 3)
            #expect(hook.prompt == nil)
        }

        /// AGY adds steps injected by hooks after the count it reports.
        @Test func ignoresStepsAddedAfterTheTurnStarted() throws {
            let hook = try turnStart(steps: ["USER_INPUT", "SYSTEM_MESSAGE"], initialNumSteps: 1)
            #expect(hook.prompt == "Continue")
        }

        @Test func recordsThePromptWhenTheTranscriptCannotSettleTheOrigin() throws {
            #expect(try turnStart(steps: ["USER_INPUT"], initialNumSteps: 3).prompt == "Continue")
            #expect(try turnStart(steps: nil, initialNumSteps: 3).prompt == "Continue")
            #expect(try turnStart(steps: ["PLANNER_RESPONSE"], initialNumSteps: nil).prompt == "Continue")
        }

        private func turnStart(steps: [String]?, initialNumSteps: Int?) throws -> AntigravityHook {
            let transcript = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-antigravity-transcript-\(UUID().uuidString).jsonl")
            if let steps {
                let lines = steps.enumerated().map { #"{"step_index":\#($0.offset),"type":"\#($0.element)"}"# }
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
            }
            var payload: [String: Any] = ["conversationId": sessionID, "lastUserInput": "Continue",
                                          "invocationNum": 0, "transcriptPath": transcript.path]
            payload["initialNumSteps"] = initialNumSteps
            return try #require(AntigravityHook(event: .userPromptSubmit, payload: payload))
        }
    }

    @Test("@spec AGENT-6.168: When Graftty returns context to Antigravity, the application shall use Antigravity's native hook output and allow Stop to complete without asking Antigravity to start another turn.")
    func emitsNativeContext() throws {
        let output = try TeamHookRenderer.sessionStart(runtime: .antigravity, instructions: "Worktree instructions.")
        let native = AntigravityHook.output(output, event: .sessionStart)
        let data = try #require(JSONSerialization.jsonObject(with: Data(native.utf8)) as? [String: Any])
        let steps = try #require(data["injectSteps"] as? [[String: Any]])
        let systemMessage = try #require(steps.first?["systemMessage"] as? [String: Any])
        #expect((systemMessage["systemMessage"] as? String)?.contains("Worktree instructions.") == true)
        #expect(data["hookSpecificOutput"] == nil)
        #expect(AntigravityHook.output(TeamHookRenderer.requestRecap(), event: .stop) == #"{"decision":"allow"}"#)
    }
}
