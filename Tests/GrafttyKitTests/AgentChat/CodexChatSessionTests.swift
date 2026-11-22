import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

/// Stands in for a Codex app-server: records what the client sends and
/// answers each request from a table.
final class FakeCodexServer: CodexChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var sentMessages: [[String: Any]] = []
    private var replies: [String: Any] = [:]
    private var held: Set<String> = []
    private var failing: Set<String> = []
    private let stream: AsyncThrowingStream<String, Error>

    init(history: String = #"{"thread":{"id":"thread-1","status":{"type":"idle"},"turns":[]}}"#) {
        var captured: AsyncThrowingStream<String, Error>.Continuation?
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
        replies = [
            "initialize": [String: Any](),
            "thread/resume": Self.object(history),
            "skills/list": ["data": [[String: Any]]()],
            "turn/start": ["turn": ["id": "turn-new"]],
            "turn/interrupt": [String: Any](),
        ]
    }

    static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func reply(to method: String, with result: String) {
        lock.withLock { replies[method] = Self.object(result) }
    }

    /// Leaves requests for `method` unanswered until `release`.
    func hold(_ method: String) { lock.withLock { _ = held.insert(method) } }
    func failSends(of method: String) { lock.withLock { _ = failing.insert(method) } }

    func release(_ method: String) {
        let pending = lock.withLock { () -> [[String: Any]] in
            held.remove(method)
            return sentMessages.filter { $0["method"] as? String == method }
        }
        for message in pending { answer(message) }
    }

    var sent: [[String: Any]] { lock.withLock { sentMessages } }
    func sent(_ method: String) -> [[String: Any]] { sent.filter { $0["method"] as? String == method } }

    func push(_ text: String) { lock.withLock { continuation }?.yield(text) }
    func disconnect() { lock.withLock { continuation }?.finish() }

    func send(_ text: String) async throws {
        let message = Self.object(text)
        let method = message["method"] as? String ?? ""
        let (shouldFail, shouldHold) = lock.withLock { () -> (Bool, Bool) in
            sentMessages.append(message)
            return (failing.contains(method), held.contains(method))
        }
        if shouldFail { throw CodexChatTransportError.closed }
        if !shouldHold { answer(message) }
    }

    private func answer(_ message: [String: Any]) {
        guard let id = message["id"], let method = message["method"] as? String,
              let result = lock.withLock({ replies[method] }),
              let data = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result])
        else { return }
        push(String(decoding: data, as: UTF8.self))
    }

    func messages() -> AsyncThrowingStream<String, Error> { stream }
    func close() async { disconnect() }
}

@Suite("CodexChatSession")
struct CodexChatSessionTests {
    private let binding = AgentChatBinding(agentID: "codex-1", assignmentID: "A", conversationID: "thread-1")

    private func started(_ server: FakeCodexServer) async throws -> CodexChatSession {
        let session = CodexChatSession(binding: binding, transport: server)
        try await session.start()
        return session
    }

    /// Waits until the session's snapshot satisfies `condition`.
    private func eventually(
        _ session: CodexChatSession, _ condition: @Sendable (AgentChatSnapshot) -> Bool
    ) async -> AgentChatSnapshot {
        for _ in 0..<400 {
            let snapshot = await session.snapshot
            if condition(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await session.snapshot
    }

    @Test func attachingRejoinsTheRunningThreadAndLoadsItsHistory() async throws {
        let server = FakeCodexServer(history: """
        {"thread":{"id":"thread-1","status":{"type":"active","activeFlags":[]},"turns":[
          {"id":"t1","status":"inProgress","items":[
            {"type":"userMessage","id":"u1","clientId":null,"content":[{"type":"text","text":"typed in the TUI"}]}]}]}}
        """)
        server.reply(to: "skills/list", with: """
        {"data":[{"cwd":"/repo","skills":[{"name":"review","description":"Review changes","enabled":true}]}]}
        """)
        let session = try await started(server)

        let resume = try #require(server.sent("thread/resume").first?["params"] as? [String: Any])
        #expect(resume["threadId"] as? String == "thread-1")
        #expect(server.sent("thread/start").isEmpty)

        let snapshot = await eventually(session) { !$0.commands.isEmpty }
        #expect(snapshot.items.map(\.text) == ["typed in the TUI"])
        #expect(snapshot.turnState == .active)
        #expect(snapshot.commands.map(\.name) == ["review"])
    }

    @Test func aJoinReplyWithoutTheConversationFailsTheAttach() async throws {
        let server = FakeCodexServer(history: "{}")
        let session = CodexChatSession(binding: binding, transport: server)
        await #expect(throws: CodexChatTransportError.self) { try await session.start() }
    }

    @Test func aLongConversationOpensWithItsLatestRows() async throws {
        let items = (1...450).map {
            #"{"type":"userMessage","id":"u\#($0)","clientId":null,"content":[{"type":"text","text":"message \#($0)"}]}"#
        }.joined(separator: ",")
        let server = FakeCodexServer(history: """
        {"thread":{"id":"thread-1","status":{"type":"idle"},"turns":[{"id":"t1","status":"completed","items":[\(items)]}]}}
        """)
        let session = try await started(server)

        let (snapshot, _) = await session.subscribe()
        #expect(snapshot.items.count == 400)
        #expect(snapshot.items.first?.text == "message 51")
        #expect(snapshot.items.last?.text == "message 450")
    }

    @Test("@spec AGENT-6.170: When a user switches views during a turn, the application shall continue displaying that turn in the selected view and show each submitted message exactly once.")
    func aTurnEnteredInTheTerminalAppearsOnceForEverySubscriber() async throws {
        let server = FakeCodexServer()
        let session = try await started(server)
        let (initial, updates) = await session.subscribe()
        #expect(initial.items.isEmpty)

        let completed = """
        {"method":"item/completed","params":{"threadId":"thread-1","turnId":"t2","completedAtMs":1,
         "item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"from TUI"}]}}}
        """
        server.push(#"{"method":"item/started","params":{"threadId":"thread-1","turnId":"t2","startedAtMs":1,"item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"from TUI"}]}}}"#)
        server.push(completed)
        server.push(#"{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"t2","itemId":"a2","delta":"BRAVO"}}"#)

        var viewer = AgentChatTranscript(snapshot: initial)
        for await update in updates {
            viewer.apply(update)
            if viewer.snapshot.items.count == 2 { break }
        }
        #expect(viewer.snapshot.items.map(\.text) == ["from TUI", "BRAVO"])
        #expect(await session.snapshot.items == viewer.snapshot.items)
    }

    @Test func aChatSubmissionStartsOneTurnOnTheBoundThread() async throws {
        let server = FakeCodexServer()
        let session = try await started(server)

        #expect(await session.submit(submissionID: "s1", text: "/review the diff") == .accepted)
        // A retry after a lost acknowledgment must not start a second turn.
        #expect(await session.submit(submissionID: "s1", text: "/review the diff") == .accepted)

        let turns = server.sent("turn/start")
        #expect(turns.count == 1)
        let params = try #require(turns.first?["params"] as? [String: Any])
        #expect(params["threadId"] as? String == "thread-1")
        #expect(params["clientUserMessageId"] as? String == "s1")
        let input = try #require((params["input"] as? [[String: Any]])?.first)
        #expect(input["text"] as? String == "/review the diff")
    }

    @Test func onlyOneOfTwoSimultaneousSubmissionsIsAdmitted() async throws {
        let server = FakeCodexServer()
        server.hold("turn/start")
        let session = try await started(server)

        async let first = session.submit(submissionID: "phone", text: "one")
        async let second = session.submit(submissionID: "mac", text: "two")
        while server.sent("turn/start").isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        server.release("turn/start")
        let results = await [first, second]

        #expect(results.filter { $0 == .accepted }.count == 1)
        #expect(results.filter { $0 == .rejected(.busy) }.count == 1)
        #expect(server.sent("turn/start").count == 1)
    }

    @Test func aSubmissionDuringATurnIsRejectedAndNothingIsSent() async throws {
        let server = FakeCodexServer()
        let session = try await started(server)
        server.push(#"{"method":"thread/status/changed","params":{"threadId":"thread-1","status":{"type":"active","activeFlags":[]}}}"#)
        _ = await eventually(session) { $0.turnState == .active }

        #expect(await session.submit(submissionID: "s2", text: "next") == .rejected(.busy))
        #expect(server.sent("turn/start").isEmpty)
    }

    @Test func aSubmissionThatMayHaveBeenDeliveredIsNeverResent() async throws {
        let server = FakeCodexServer()
        let session = try await started(server)
        server.hold("turn/start")

        async let result = session.submit(submissionID: "s3", text: "maybe")
        while server.sent("turn/start").isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }
        server.disconnect()

        #expect(await result == .uncertain)
        #expect(await session.submit(submissionID: "s3", text: "maybe") == .uncertain)
        #expect(server.sent("turn/start").count == 1)
    }

    @Test("@spec AGENT-6.171: When a user switches views with a provider request pending, the application shall preserve the request for an explicit answer and remove its action from Chat once the provider resolves it.")
    func anApprovalIsAnsweredOnceAndClearedWhenTheProviderResolvesIt() async throws {
        let server = FakeCodexServer()
        let session = try await started(server)
        server.push("""
        {"id":7,"method":"item/commandExecution/requestApproval","params":{"kind":"command",
         "threadId":"thread-1","turnId":"t","itemId":"exec-1","startedAtMs":1,"command":"touch f"}}
        """)
        let pending = await eventually(session) { !$0.requests.isEmpty }
        #expect(pending.requests.map(\.id) == ["7"])

        #expect(await session.answer(requestID: "7", decision: .accept))
        #expect(await session.answer(requestID: "7", decision: .decline) == false)

        let replies = server.sent.filter { $0["method"] == nil && ($0["id"] as? Int) == 7 }
        #expect(replies.count == 1)
        #expect((replies.first?["result"] as? [String: Any])?["decision"] as? String == "accept")

        server.push(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":7}}"#)
        let cleared = await eventually(session) { $0.requests.isEmpty }
        #expect(cleared.requests.isEmpty)
    }

    @Test func aRequestAnsweredInTheTerminalCannotBeAnsweredFromChat() async throws {
        let server = FakeCodexServer()
        let session = try await started(server)
        server.push("""
        {"id":8,"method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"t",
         "itemId":"p1","startedAtMs":1}}
        """)
        _ = await eventually(session) { !$0.requests.isEmpty }
        server.push(#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":8}}"#)
        _ = await eventually(session) { $0.requests.isEmpty }

        #expect(await session.answer(requestID: "8", decision: .accept) == false)
        #expect(server.sent.filter { $0["method"] == nil }.isEmpty)
    }

    @Test func aChangedSkillListReplacesTheCommands() async throws {
        let server = FakeCodexServer()
        server.reply(to: "skills/list", with: """
        {"data":[{"cwd":"/repo","skills":[{"name":"old","description":"Old","enabled":true}]}]}
        """)
        let session = try await started(server)
        _ = await eventually(session) { $0.commands.map(\.name) == ["old"] }

        server.reply(to: "skills/list", with: #"{"data":[{"cwd":"/repo","skills":[]}]}"#)
        server.push(#"{"method":"skills/changed","params":{}}"#)
        let updated = await eventually(session) { $0.commands.isEmpty }
        #expect(updated.commands.isEmpty)
    }

    @Test func afterTheAgentExitsNothingCanBeSent() async throws {
        let server = FakeCodexServer()
        let session = try await started(server)
        server.disconnect()
        let ended = await eventually(session) { $0.endedReason != nil }
        #expect(ended.endedReason != nil)

        #expect(await session.submit(submissionID: "late", text: "hello") == .rejected(.ended))
        #expect(server.sent("turn/start").isEmpty)
    }
}
