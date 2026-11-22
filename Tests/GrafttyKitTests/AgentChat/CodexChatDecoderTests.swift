import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("CodexChatDecoder")
struct CodexChatDecoderTests {
    private let thread = "thread-1"

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func aUserMessageKeepsItsSubmissionID() throws {
        let params = try json("""
        {"threadId":"thread-1","turnId":"turn-2","completedAtMs":1,
         "item":{"type":"userMessage","id":"u2","clientId":"from-gui-3",
                 "content":[{"type":"text","text":"Run the tests","text_elements":[]},
                            {"type":"localImage","path":"/tmp/a.png"}]}}
        """)
        let events = CodexChatDecoder.events(notification: "item/completed", params: params, threadID: thread)
        #expect(events == [.item(AgentChatItem(
            id: "u2", turnID: "turn-2", kind: .user, text: "Run the tests\n[image]",
            submissionID: "from-gui-3", isComplete: true
        ))])
    }

    @Test func aRunningCommandCompletesWithItsOutput() throws {
        let started = try json("""
        {"threadId":"thread-1","turnId":"t","startedAtMs":1,
         "item":{"type":"commandExecution","id":"c1","command":"swift test","cwd":"/repo",
                 "status":"inProgress","aggregatedOutput":null,"exitCode":null}}
        """)
        let completed = try json("""
        {"threadId":"thread-1","turnId":"t","completedAtMs":2,
         "item":{"type":"commandExecution","id":"c1","command":"swift test","cwd":"/repo",
                 "status":"completed","aggregatedOutput":"ok\\n","exitCode":0}}
        """)
        #expect(CodexChatDecoder.events(notification: "item/started", params: started, threadID: thread) == [
            .item(AgentChatItem(id: "c1", turnID: "t", kind: .command, text: "swift test", isComplete: false)),
        ])
        #expect(CodexChatDecoder.events(notification: "item/completed", params: completed, threadID: thread) == [
            .item(AgentChatItem(id: "c1", turnID: "t", kind: .command, text: "swift test",
                                detail: "ok\n", isComplete: true)),
        ])
    }

    @Test func reasoningWithNoSummaryLeavesNoRow() throws {
        let started = try json("""
        {"threadId":"thread-1","turnId":"t","startedAtMs":1,
         "item":{"type":"reasoning","id":"r1","summary":[],"content":[]}}
        """)
        #expect(CodexChatDecoder.events(notification: "item/started", params: started, threadID: thread).isEmpty)
        #expect(CodexChatDecoder.events(notification: "item/completed", params: started, threadID: thread).isEmpty)
    }

    @Test func longCommandOutputKeepsItsTail() throws {
        let output = String(repeating: "x", count: 20_000) + "END"
        let params: [String: Any] = [
            "threadId": "thread-1", "turnId": "t",
            "item": ["type": "commandExecution", "id": "c1", "command": "make", "status": "completed",
                     "aggregatedOutput": output],
        ]
        let events = CodexChatDecoder.events(notification: "item/completed", params: params, threadID: thread)
        guard case .item(let item)? = events.first else { Issue.record("no item"); return }
        #expect(item.detail?.count == 8_000)
        #expect(item.detail?.hasSuffix("END") == true)
    }

    @Test func streamedReplyTextBecomesDeltas() throws {
        let params = try json(#"{"threadId":"thread-1","turnId":"t","itemId":"a1","delta":"Hel"}"#)
        #expect(CodexChatDecoder.events(notification: "item/agentMessage/delta", params: params, threadID: thread)
            == [.textDelta(itemID: "a1", turnID: "t", kind: .agent, delta: "Hel")])
    }

    @Test func eventsFromAnotherThreadAreIgnored() throws {
        let params = try json(#"{"threadId":"subagent","turnId":"t","itemId":"a1","delta":"Hel"}"#)
        #expect(CodexChatDecoder.events(notification: "item/agentMessage/delta", params: params, threadID: thread)
            .isEmpty)
        let status = try json(#"{"threadId":"subagent","status":{"type":"idle"}}"#)
        #expect(CodexChatDecoder.events(notification: "thread/status/changed", params: status, threadID: thread)
            .isEmpty)
    }

    @Test func threadStatusMapsToTurnState() throws {
        func state(_ status: String) throws -> [AgentChatEvent] {
            CodexChatDecoder.events(
                notification: "thread/status/changed",
                params: try json(#"{"threadId":"thread-1","status":\#(status)}"#),
                threadID: thread
            )
        }
        #expect(try state(#"{"type":"idle"}"#) == [.turnState(.idle)])
        #expect(try state(#"{"type":"active","activeFlags":[]}"#) == [.turnState(.active)])
        #expect(try state(#"{"type":"active","activeFlags":["waitingOnApproval"]}"#)
            == [.turnState(.waitingOnRequest)])
    }

    @Test func aCommandApprovalIsAnswerableInChat() throws {
        let params = try json("""
        {"kind":"command","threadId":"thread-1","turnId":"t","itemId":"exec-1","startedAtMs":1,
         "command":"/bin/zsh -lc 'touch probe-file'","cwd":"/repo","reason":"needs write access"}
        """)
        let request = CodexChatDecoder.request(
            id: "0", method: "item/commandExecution/requestApproval", params: params, threadID: thread
        )
        #expect(request == AgentChatPendingRequest(
            id: "0", kind: .commandApproval, summary: "/bin/zsh -lc 'touch probe-file'",
            detail: "needs write access", canAnswerInChat: true
        ))
    }

    @Test func aQuestionOnlyTheTerminalCanAnswerStaysVisible() throws {
        let params = try json(#"{"threadId":"thread-1","turnId":"t","itemId":"q"}"#)
        let request = CodexChatDecoder.request(
            id: "4", method: "item/tool/requestUserInput", params: params, threadID: thread
        )
        #expect(request?.kind == .other)
        #expect(request?.canAnswerInChat == false)
        #expect(CodexChatDecoder.request(
            id: "5", method: "item/tool/requestUserInput",
            params: try json(#"{"threadId":"other"}"#), threadID: thread
        ) == nil)
    }

    @Test func aResolvedRequestAndAClosedThreadAreReported() throws {
        let resolved = try json(#"{"threadId":"thread-1","requestId":0}"#)
        #expect(CodexChatDecoder.events(notification: "serverRequest/resolved", params: resolved, threadID: thread)
            == [.requestResolved(id: "0")])
        let closed = try json(#"{"threadId":"thread-1"}"#)
        #expect(CodexChatDecoder.events(notification: "thread/closed", params: closed, threadID: thread).count == 1)
    }

    @Test func aThreadReadBecomesOrderedHistory() throws {
        let result = try json("""
        {"thread":{"id":"thread-1","status":{"type":"active","activeFlags":[]},"turns":[
          {"id":"t1","status":"completed","items":[
            {"type":"userMessage","id":"u1","clientId":null,"content":[{"type":"text","text":"hi"}]},
            {"type":"hookPrompt","id":"h1","fragments":[]},
            {"type":"agentMessage","id":"a1","text":"ALPHA"}]},
          {"id":"t2","status":"inProgress","items":[
            {"type":"userMessage","id":"u2","clientId":"s2","content":[{"type":"text","text":"more"}]},
            {"type":"agentMessage","id":"a2","text":"BRA"}]}]}}
        """)
        let history = try #require(CodexChatDecoder.history(threadResult: result))
        #expect(history.items.map(\.id) == ["u1", "a1", "u2", "a2"])
        #expect(history.items.map(\.isComplete) == [true, true, true, false])
        #expect(history.turnState == .active)
        #expect(history.activeTurnID == "t2")
    }

    @Test func enabledSkillsBecomeCommands() throws {
        let result = try json("""
        {"data":[{"cwd":"/repo","skills":[
          {"name":"review","description":"Long text","shortDescription":"Review changes","enabled":true,
           "path":"/skills/review/SKILL.md"},
          {"name":"off","description":"Disabled","enabled":false}]}]}
        """)
        let skills = CodexChatDecoder.skills(skillsResult: result)
        #expect(skills.map(\.command) == [
            AgentChatCommand(name: "review", description: "Review changes", invocation: "$review"),
        ])

        let mentioned = CodexChatDecoder.input(text: "$review the last commit", skills: skills)
        #expect(mentioned.count == 2)
        #expect(mentioned[0]["text"] as? String == "$review the last commit")
        #expect(mentioned[1]["type"] as? String == "skill")
        #expect(mentioned[1]["path"] as? String == "/skills/review/SKILL.md")
        #expect(CodexChatDecoder.input(text: "pay $reviewers", skills: skills).count == 1)
    }
}
