import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("AgentChatTranscript")
struct AgentChatTranscriptTests {
    private let binding = AgentChatBinding(agentID: "codex-1", assignmentID: "A", conversationID: "T")

    private func transcript(_ items: [AgentChatItem] = [], sequence: Int = 0) -> AgentChatTranscript {
        AgentChatTranscript(snapshot: AgentChatSnapshot(binding: binding, items: items, sequence: sequence))
    }

    private func user(_ id: String, _ text: String) -> AgentChatItem {
        AgentChatItem(id: id, turnID: "t1", kind: .user, text: text, isComplete: true)
    }

    @Test func replayedUpdatesLeaveOneRowPerMessage() {
        var transcript = transcript([user("u1", "hello")], sequence: 2)
        let replayed = AgentChatUpdate(sequence: 2, event: .item(user("u1", "hello")))
        let fresh = AgentChatUpdate(sequence: 3, event: .item(user("u2", "again")))

        let applied = [transcript.apply(replayed), transcript.apply(fresh), transcript.apply(fresh)]
        #expect(applied == [false, true, false])

        #expect(transcript.snapshot.items.map(\.id) == ["u1", "u2"])
        #expect(transcript.snapshot.sequence == 3)
    }

    @Test func historyAndLiveEventsForTheSameItemMergeInOrder() {
        var transcript = transcript([user("u1", "hello")])
        transcript.apply(.textDelta(itemID: "a1", turnID: "t1", kind: .agent, delta: "Hi "))
        transcript.apply(.textDelta(itemID: "a1", turnID: "t1", kind: .agent, delta: "there"))
        #expect(transcript.snapshot.items.last?.text == "Hi there")
        #expect(transcript.snapshot.items.last?.isComplete == false)

        let done = AgentChatItem(id: "a1", turnID: "t1", kind: .agent, text: "Hi there.", isComplete: true)
        transcript.apply(.item(done))
        // Stale live events that overlap the completed history row.
        transcript.apply(.item(AgentChatItem(id: "a1", turnID: "t1", kind: .agent, text: "", isComplete: false)))
        transcript.apply(.textDelta(itemID: "a1", turnID: "t1", kind: .agent, delta: "Hi "))

        #expect(transcript.snapshot.items.map(\.id) == ["u1", "a1"])
        #expect(transcript.snapshot.items.last == done)
    }

    @Test func aResolvedRequestLeavesNoAction() {
        var transcript = transcript()
        let request = AgentChatPendingRequest(
            id: "0", kind: .commandApproval, summary: "touch file", canAnswerInChat: true
        )
        transcript.apply(.requestOpened(request))
        transcript.apply(.requestOpened(request))
        #expect(transcript.snapshot.requests == [request])

        transcript.apply(.requestResolved(id: "0"))
        #expect(transcript.snapshot.requests.isEmpty)
    }

    @Test("@spec AGENT-6.166: When the running agent advertises a new command list, the application shall replace the slash menu in that tab's Chat view with the advertised names, descriptions, and argument hints.")
    func aCommandUpdateReplacesTheWholeList() {
        var transcript = transcript()
        transcript.apply(.commands([
            AgentChatCommand(name: "review", description: "Review changes"),
            AgentChatCommand(name: "compact", description: "Compact"),
        ]))
        transcript.apply(.commands([AgentChatCommand(name: "plan", description: "Plan", argumentHint: "<goal>")]))
        #expect(transcript.snapshot.commands.map(\.name) == ["plan"])

        transcript.apply(.commands([]))
        #expect(transcript.snapshot.commands.isEmpty)
    }

    @Test func endingTheConversationDropsPendingRequests() {
        var transcript = transcript()
        transcript.apply(.turnState(.waitingOnRequest))
        transcript.apply(.requestOpened(AgentChatPendingRequest(
            id: "0", kind: .other, summary: "question", canAnswerInChat: false
        )))
        transcript.apply(.ended(reason: "The agent switched conversations."))

        #expect(transcript.snapshot.requests.isEmpty)
        #expect(transcript.snapshot.turnState == .idle)
        #expect(transcript.snapshot.endedReason == "The agent switched conversations.")
    }

    @Test func aLeadingSlashOpensTheMenuUntilTheNameEnds() {
        let commands = [
            AgentChatCommand(name: "review", description: "Review", invocation: "$review"),
            AgentChatCommand(name: "preview", description: "Preview"),
            AgentChatCommand(name: "compact", description: "Compact"),
        ]
        #expect(AgentChatSlashQuery(draft: "/", commands: commands)?.matches.count == 3)
        #expect(AgentChatSlashQuery(draft: "/rev", commands: commands)?.matches.map(\.name) == ["review", "preview"])
        #expect(AgentChatSlashQuery(draft: "/review ", commands: commands) == nil)
        #expect(AgentChatSlashQuery(draft: "open src/main.swift", commands: commands) == nil)
        #expect(AgentChatSlashQuery(draft: " /review", commands: commands) == nil)
        #expect(AgentChatSlashQuery(draft: "/zzz", commands: commands) == nil)
        #expect(AgentChatSlashQuery(draft: "/", commands: []) == nil)

        #expect(AgentChatSlashQuery.draft(choosing: commands[0]) == "$review ")
        #expect(AgentChatSlashQuery.draft(choosing: commands[1]) == "/preview ")
    }

    @Test func updatesSurviveTheWire() throws {
        let updates = [
            AgentChatUpdate(sequence: 1, event: .textDelta(itemID: "a", turnID: nil, kind: .agent, delta: "x")),
            AgentChatUpdate(sequence: 2, event: .requestResolved(id: "7")),
            AgentChatUpdate(sequence: 3, event: .commands([AgentChatCommand(name: "n", description: "d")])),
        ]
        let data = try JSONEncoder().encode(updates)
        #expect(try JSONDecoder().decode([AgentChatUpdate].self, from: data) == updates)
    }
}
