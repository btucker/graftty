import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("@spec CONTEXT-50: When a Claude AskUserQuestion result or a Codex request_user_input result supplies human answers in a transcript, the application shall capture one structured reply at its original time through the durable handoff, match each answer to its question call across hook invocations, and exclude unrelated tool results, other sessions, and subagents.")
struct HarnessQuestionCaptureTests {
    private var claudeQuestion: [String: Any] {
        ["type": "assistant", "sessionId": "session", "timestamp": "2026-10-28T18:29:59Z",
         "message": ["role": "assistant", "content": [["type": "tool_use", "id": "question-tool", "name": "AskUserQuestion",
            "input": ["questions": [["question": "Which approach?"], ["question": "Targets?"]]]]]]]
    }

    private var claudeAnswer: [String: Any] {
        ["type": "user", "uuid": "answer-record", "sessionId": "session", "timestamp": "2026-10-28T18:30:00Z",
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "question-tool", "content": "Human reply"]]],
         "toolUseResult": ["questions": [["question": "Which approach?"], ["question": "Targets?"]],
                           "answers": ["Targets?": "Mac and mobile", "Which approach?": "Design first"]]]
    }

    @Test func claudeCapturesStructuredResultsOnceAndRejectsOtherSources() throws {
        func parse(_ record: [String: Any]) throws -> WorktreeHistory.UserInput? {
            var state = HarnessTimelineTranscriptState()
            _ = AgentResponseCapture.input(from: try JSONSerialization.data(withJSONObject: claudeQuestion), runtime: .claude,
                sessionID: "session", state: &state)
            return AgentResponseCapture.input(from: try JSONSerialization.data(withJSONObject: record), runtime: .claude,
                sessionID: "session", state: &state)
        }
        let input = try #require(try parse(claudeAnswer))
        #expect(input.timestamp == 814_905_000)
        #expect(input.parts?.first?.presentation?.items.map(\.value) == ["Design first", "Mac and mobile"])
        #expect(try parse(claudeAnswer)?.id == input.id)
        for (key, value) in [("isSidechain", true as Any), ("sessionId", "other" as Any), ("type", "api-request" as Any), ("toolUseResult", ["output": "Tool text"] as Any)] {
            var record = claudeAnswer
            record[key] = value
            #expect(try parse(record) == nil)
        }
    }

    @Test func claudeRequiresTheMatchingQuestionToolCall() throws {
        var state = HarnessTimelineTranscriptState()
        let answer = try JSONSerialization.data(withJSONObject: claudeAnswer)
        #expect(AgentResponseCapture.input(from: answer, runtime: .claude, sessionID: "session", state: &state) == nil)
        _ = AgentResponseCapture.input(from: try JSONSerialization.data(withJSONObject: claudeQuestion), runtime: .claude,
            sessionID: "session", state: &state)
        var unrelated = claudeAnswer
        unrelated["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "shell-call", "content": "Tool output"]]]
        #expect(AgentResponseCapture.input(from: try JSONSerialization.data(withJSONObject: unrelated), runtime: .claude,
            sessionID: "session", state: &state) == nil)
        #expect(AgentResponseCapture.input(from: answer, runtime: .claude, sessionID: "session", state: &state) != nil)
    }

    @Test(arguments: [TeamHookRuntime.codex, .claude])
    func nativeQuestionCallsMatchAcrossCapturesAndSurviveReplay(runtime: TeamHookRuntime) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let call: [String: Any] = runtime == .claude ? claudeQuestion : ["type": "response_item", "timestamp": "2026-10-28T18:29:59Z",
            "payload": ["type": "function_call", "name": "request_user_input", "call_id": "call-1",
                        "arguments": #"{"questions":[{"id":"approach","question":"Which approach?"}]}"#]]
        let answer: [String: Any] = runtime == .claude ? claudeAnswer : ["type": "response_item", "timestamp": "2026-10-28T18:30:00Z",
            "payload": ["type": "function_call_output", "call_id": "call-1", "output": #"{"answers":{"approach":{"answers":["Design first","Then implement"]}}}"#]]
        var data = try JSONSerialization.data(withJSONObject: call)
        data.append(0x0A)
        try data.write(to: file)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("handoff"))
        let capture = AgentResponseCapture(handoff: handoff)
        let payload: [String: Any] = ["transcript_path": file.path]
        try capture.capture(payload: payload, runtime: runtime, worktree: "/task", sessionID: "session")
        data.append(try JSONSerialization.data(withJSONObject: answer))
        data.append(0x0A)
        try data.write(to: file)
        try capture.capture(payload: payload, runtime: runtime, worktree: "/task", sessionID: "session")
        try capture.capture(payload: payload, runtime: runtime, worktree: "/task", sessionID: "session")
        var history = WorktreeHistory()
        try handoff.consumeActivities {
            guard case .progress(let event) = $0, let input = event.userInput else { Issue.record("Expected captured reply"); return }
            history.record(input)
        }
        #expect(history.inputs.count == 1)
        #expect(history.inputs.first?.timestamp == 814_905_000)
        let content = WorktreeTimeline(history: history, brief: nil).events.first?.presentation
        #expect(content?.items.first?.label == "Which approach?")
        #expect(content?.items.first?.value == (runtime == .claude ? "Design first" : "Design first\nThen implement"))
        #expect(content?.items.count == (runtime == .claude ? 2 : 1))
        #expect(try handoff.consumeActivities { _ in Issue.record("Unchanged capture must not replay answers") } == 0)
        try FileManager.default.removeItem(at: handoff.rootDirectory.appendingPathComponent("transcript-cursors"))
        try capture.capture(payload: payload, runtime: runtime, worktree: "/task", sessionID: "session")
        try handoff.consumeActivities { if case .progress(let event) = $0, let input = event.userInput { history.record(input) } }
        #expect(history.inputs.count == 1, "Rebuilding a cursor must preserve the reply's original identity")
    }

    @Test func largeStructuredAnswersSurviveTheDurableHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        var record = claudeAnswer
        record["toolUseResult"] = ["questions": [["question": "Which approach?"]],
                                  "answers": ["Which approach?": String(repeating: "😀", count: 5000)]]
        var state = HarnessTimelineTranscriptState()
        _ = AgentResponseCapture.input(from: try JSONSerialization.data(withJSONObject: claudeQuestion), runtime: .claude,
            sessionID: "session", state: &state)
        let input = try #require(AgentResponseCapture.input(from: try JSONSerialization.data(withJSONObject: record),
            runtime: .claude, sessionID: "session", state: &state))
        #expect(input.wasTruncated)
        #expect(try JSONEncoder().encode(input).count > 16_384)
        try handoff.input(input, worktree: "/task", runtime: .claude, sessionID: "session")
        var captured: WorktreeHistory.UserInput?
        #expect(try handoff.consumeActivities { if case .progress(let event) = $0 { captured = event.userInput } } == 1)
        #expect(captured == input)
    }
}
