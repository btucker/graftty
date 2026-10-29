import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("@spec CONTEXT-41: When Codex or Claude hooks expose a session transcript, the application shall capture visible assistant responses incrementally through the durable handoff, exclude reasoning, tool output and subagent responses, tolerate incomplete records, and replay responses without duplicating history or clearing attention.")
struct AgentResponseCaptureTests {
    private func codex(_ text: String, phase: String = "commentary", id: String = "message", time: String = "2026-10-28T18:30:00Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": time, "type": "response_item",
            "payload": ["type": "message", "id": id, "role": "assistant", "phase": phase,
                        "content": [["type": "output_text", "text": text]]]])
    }

    @Test func visibleCodexMessagesHaveStableIdentityAndOriginalTime() throws {
        let data = try codex("I will implement B on both platforms.")
        let response = try #require(AgentResponseCapture.response(from: data, runtime: .codex, sessionID: "session"))
        #expect(response.text == "I will implement B on both platforms.")
        #expect(response.timestamp == 814_905_000)
        #expect(response.sessionID == "session")
        #expect(response.isFinal == false)
        #expect(AgentResponseCapture.response(from: try codex("Done.", phase: "final"), runtime: .codex, sessionID: "session")?.isFinal == true)
        #expect(response.id == AgentResponseCapture.response(from: data, runtime: .codex, sessionID: "session", offset: 900)?.id)
        #expect(response.id != AgentResponseCapture.response(from: data, runtime: .codex, sessionID: "another")?.id)
        #expect(AgentResponseCapture.response(from: try codex("Private thoughts", phase: "analysis"), runtime: .codex, sessionID: "session") == nil)
    }

    @Test("@spec CONTEXT-44: When a provider finishes a turn, the application shall retain its session and final-response boundary, including when the Stop hook follows an already captured message, so that the timeline generates one summary after completion.")
    func stopMarksAnAlreadyDrainedResponseFinalExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var data = try codex("The final result.")
        data.append(0x0A)
        try data.write(to: file)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("handoff"))
        let capture = AgentResponseCapture(handoff: handoff)
        let payload: [String: Any] = ["transcript_path": file.path]
        var history = WorktreeHistory()
        try capture.capture(payload: payload, runtime: .codex, worktree: "/task", sessionID: "session")
        try handoff.consumeActivities { if case .response(let event) = $0 { history.record(event.response) } }
        #expect(history.responses.first?.isFinal == false)
        try capture.capture(payload: payload, runtime: .codex, worktree: "/task", sessionID: "session", turnCompleted: true)
        try handoff.consumeActivities { if case .response(let event) = $0 { history.record(event.response) } }
        #expect(history.responses.count == 1)
        #expect(history.responses.first?.isFinal == true)
        try capture.capture(payload: payload, runtime: .codex, worktree: "/task", sessionID: "session", turnCompleted: true)
        #expect(try handoff.consumeActivities { _ in Issue.record("Repeated Stop must not re-publish completion") } == 0)
    }

    @Test func claudeCapturesTextWithoutThinkingToolCallsOrSidechains() throws {
        let record: [String: Any] = ["type": "assistant", "uuid": "uuid", "sessionId": "session",
            "timestamp": "2026-10-28T18:30:00.000Z", "message": ["role": "assistant", "id": "message",
                "content": [["type": "thinking", "thinking": "Hidden"], ["type": "text", "text": "Implementing B."],
                            ["type": "tool_use", "name": "Bash", "input": [:]]]]]
        func parse(_ record: [String: Any]) throws -> WorktreeHistory.AgentResponse? {
            AgentResponseCapture.response(from: try JSONSerialization.data(withJSONObject: record), runtime: .claude, sessionID: "session")
        }
        #expect(try parse(record)?.text == "Implementing B.")
        var sidechain = record
        sidechain["isSidechain"] = true
        #expect(try parse(sidechain) == nil)
        var wrongSession = record
        wrongSession["sessionId"] = "another"
        #expect(try parse(wrongSession) == nil)
        #expect(AgentResponseCapture.response(from: Data("not json".utf8), runtime: .codex, sessionID: "session") == nil)
    }

    @Test func cursorKeepsPartialRecordsAndHandoffSurvivesReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var data = try codex("First response.")
        data.append(0x0A)
        let second = try codex("Second response.", id: "second", time: "2026-10-28T18:30:01Z")
        data.append(second.prefix(30))
        try data.write(to: file)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("handoff"))
        let capture = AgentResponseCapture(handoff: handoff)
        let payload: [String: Any] = ["transcript_path": file.path]
        try capture.capture(payload: payload, runtime: .codex, worktree: "/repo/task", sessionID: "session")
        data.append(second.dropFirst(30))
        data.append(0x0A)
        try data.write(to: file)
        try capture.capture(payload: payload, runtime: .codex, worktree: "/repo/task", sessionID: "session")
        try capture.capture(payload: payload, runtime: .codex, worktree: "/repo/task", sessionID: "session")
        var responses: [WorktreeHistory.AgentResponse] = []
        try handoff.consumeActivities { event in
            if case .response(let event) = event { responses.append(event.response) }
            else { Issue.record("Capturing responses must not emit progress or stop attention transitions") }
        }
        #expect(responses.map(\.text) == ["First response.", "Second response."])
        try capture.capture(payload: payload, runtime: .codex, worktree: "/repo/task", sessionID: "session")
        #expect(try handoff.consumeActivities { _ in Issue.record("An unchanged transcript must not republish drained responses") } == 0)
    }

    @Test func largeToolRecordsDoNotDelayTheLatestResponse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var data = Data(repeating: 0x78, count: 3 * 1024 * 1024)
        data.append(0x0A)
        data.append(try codex("The latest update."))
        data.append(0x0A)
        try data.write(to: file)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("handoff"))
        let capture = AgentResponseCapture(handoff: handoff)
        try capture.capture(payload: ["transcript_path": file.path], runtime: .codex, worktree: "/task", sessionID: "session")
        var responses: [String] = []
        try handoff.consumeActivities { if case .response(let event) = $0 { responses.append(event.response.text) } }
        #expect(responses == ["The latest update."])
    }

    @Test func establishedCursorPreservesRepliesBeforeLargeToolRecordsAndAcceptsNullAgentID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var data = try codex("Initial reply.", id: "initial")
        data.append(0x0A)
        try data.write(to: file)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("handoff"))
        let capture = AgentResponseCapture(handoff: handoff)
        try capture.capture(payload: ["transcript_path": file.path], runtime: .codex, worktree: "/task", sessionID: "session")
        _ = try handoff.consumeActivities { _ in }
        data.append(try codex("Before the tool.", id: "before"))
        data.append(0x0A)
        data.append(Data(repeating: 0x78, count: 3 * 1024 * 1024))
        data.append(0x0A)
        data.append(try codex("After the tool.", id: "after", time: "2026-10-28T18:30:01Z"))
        data.append(0x0A)
        try data.write(to: file)
        try capture.capture(payload: ["transcript_path": file.path, "agent_id": NSNull()],
                            runtime: .codex, worktree: "/task", sessionID: "session")
        var responses: [String] = []
        try handoff.consumeActivities { if case .response(let event) = $0 { responses.append(event.response.text) } }
        #expect(responses == ["Before the tool.", "After the tool."])
        #expect(try handoff.consumeActivities { _ in Issue.record("Replies must be drained once") } == 0)
    }

    @Test func changingWorktreeDoesNotReplayTheSameSessionIntoAnotherHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var data = try codex("A reply for the original worktree.")
        data.append(0x0A)
        try data.write(to: file)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("handoff"))
        let capture = AgentResponseCapture(handoff: handoff)
        let payload: [String: Any] = ["transcript_path": file.path]
        try capture.capture(payload: payload, runtime: .codex, worktree: "/task/A", sessionID: "session")
        _ = try handoff.consumeActivities { _ in }
        try capture.capture(payload: payload, runtime: .codex, worktree: "/task/B", sessionID: "session")
        #expect(try handoff.consumeActivities { _ in Issue.record("Changing directories must not replay old replies") } == 0)
        try capture.capture(payload: payload, runtime: .codex, worktree: "/task/B", sessionID: "session", turnCompleted: true)
        let completions = try handoff.consumeActivities {
            guard case .response(let event) = $0 else { Issue.record("Expected response completion"); return }
            #expect(event.worktree == "/task/A")
            #expect(event.response.isFinal == true)
        }
        #expect(completions == 1)
    }

    @Test func initialTailStartingAtARecordBoundaryKeepsTheFirstCompleteReply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var tail = try codex("A complete reply at the start of the tail.")
        tail.append(0x0A)
        tail.append(Data(repeating: 0x78, count: 2 * 1024 * 1024 - tail.count - 1))
        tail.append(0x0A)
        var data = Data("older record\n".utf8)
        data.append(tail)
        try data.write(to: file)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("handoff"))
        try AgentResponseCapture(handoff: handoff).capture(payload: ["transcript_path": file.path],
            runtime: .codex, worktree: "/task", sessionID: "session")
        var replies: [String] = []
        try handoff.consumeActivities { if case .response(let event) = $0 { replies.append(event.response.text) } }
        #expect(replies == ["A complete reply at the start of the tail."])
    }
}
