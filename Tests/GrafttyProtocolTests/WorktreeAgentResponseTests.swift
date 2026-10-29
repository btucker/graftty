import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec CONTEXT-40: When a provider emits a visible agent response, the application shall retain it once in worktree history independently of attention, order it between human inputs and other events by its original time, and include it in one expandable turn summary with the captured text available on Mac and mobile.")
struct WorktreeAgentResponseTests {
    @Test("@spec CONTEXT-42: When worktree history shows agent responses on Mac or mobile, the application shall show one stable row per agent turn across intervening recaps, summarize only its first and last visible messages, retain all captured messages for expansion, and separate turns at provider completion or a new input.")
    func repliesShareOneTurnAcrossRecapsAndSeparateAtInput() throws {
        let start = Date(timeIntervalSince1970: 100)
        var history = WorktreeHistory()
        history.record(.init(text: "Fix the timeline.", at: start))
        for (offset, text) in ["I will inspect it.", "I found the cause.", "Fixed and verified."].enumerated() {
            history.record(WorktreeHistory.AgentResponse(id: "reply-\(offset)", text: text,
                at: start.addingTimeInterval(Double(offset + 1)), runtime: "codex"))
        }
        let brief = WorktreeBrief(recap: .init(title: "Timeline", completed: "Investigating.", next: "Fix.",
            historyEntry: .init(headline: "Found a layout shift.")), at: start.addingTimeInterval(2.5))
        history.record(.init(text: "Also check mobile.", at: start.addingTimeInterval(4)))
        history.record(WorktreeHistory.AgentResponse(id: "next", text: "Mobile verified.",
            at: start.addingTimeInterval(5), runtime: "codex"))
        let timeline = WorktreeTimeline(history: history, brief: brief)
        for showAll in [false, true] {
            let rows = timeline.rows(showAll: showAll)
            let turns = rows.filter { $0.events.first?.kind == .agentResponse }
            #expect(turns.count == 2)
            #expect(turns.first?.id == "reply-0", "The turn keeps its first message's identity as replies arrive")
            #expect(turns.first?.events.map(\.completed) == ["I will inspect it.", "I found the cause.", "Fixed and verified."])
            #expect(turns.first?.summaryInput == "First agent message:\nI will inspect it.\n\nLast agent message:\nFixed and verified.")
            #expect(rows.map(\.events.count) == [1, 3, 1, 1, 1])
        }
        #expect(timeline.events.count == 7, "Original messages remain available to terminal navigation")
    }

    @Test func providerCompletionAndSessionsSeparateTurnsWithoutNewInputs() throws {
        let start = Date(timeIntervalSince1970: 100)
        var history = WorktreeHistory()
        func response(_ id: String, _ session: String, final: Bool) -> WorktreeHistory.AgentResponse {
            .init(id: id, text: id, at: start.addingTimeInterval(Double(history.responses.count)),
                  runtime: "codex", sessionID: session, isFinal: final)
        }
        history.record(response("start-a", "a", final: false))
        history.record(response("start-b", "b", final: false))
        history.record(response("end-a", "a", final: true))
        history.record(response("next-a", "a", final: false))
        var rows = WorktreeTimeline(history: history, brief: nil).rows(showAll: false)
        #expect(rows.map(\.id) == ["start-a", "start-b", "next-a"])
        #expect(rows.map(\.isComplete) == [true, false, false])
        #expect(rows[0].summaryInput == "First agent message:\nstart-a\n\nLast agent message:\nend-a")
        history.record(.init(text: "Interrupt.", at: start.addingTimeInterval(10)))
        rows = WorktreeTimeline(history: history, brief: nil).rows(showAll: false)
        #expect(rows.allSatisfy { $0.isComplete }, "The next input closes interrupted turns")
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.responses == history.responses)
    }

    @Test func responsesStayBetweenTheRequestsTheyAnswerAndSurviveReplay() throws {
        let start = Date(timeIntervalSince1970: 100)
        var history = WorktreeHistory()
        history.record(.init(text: "I like B.", at: start))
        let response = WorktreeHistory.AgentResponse(id: "codex:session:message", text: "I will implement B on both platforms.",
            at: start.addingTimeInterval(1), runtime: "codex")
        history.record(response)
        history.record(response)
        history.record(.init(text: "Include agent responses too.", at: start.addingTimeInterval(2)))
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.responses == [response])
        let timeline = WorktreeTimeline(history: restored, brief: nil)
        #expect(timeline.events.map(\.completed) == ["I like B.", response.text, "Include agent responses too."])
        #expect(timeline.rows(showAll: false).count == 3, "A response prevents merging the surrounding human inputs")
        #expect(timeline.events[1].title == "Codex")
        #expect(timeline.events[1].sourceWorktreePath == nil, "A local response is not a peer worktree link")
    }

    @Test func legacyHistoryDecodesAndResponseRetentionIsBounded() throws {
        var history = try JSONDecoder().decode(WorktreeHistory.self, from: Data("{\"inputs\":[]}".utf8))
        #expect(history.responses.isEmpty)
        for index in 0..<140 {
            history.record(WorktreeHistory.AgentResponse(id: "\(index)", text: "Response \(index)",
                at: Date(timeIntervalSince1970: Double(index)), runtime: "claude"))
        }
        #expect(history.responses.count == 128)
        #expect(history.responses.first?.id == "12")
        let long = WorktreeHistory.AgentResponse(id: "long", text: String(repeating: "🧭", count: 5000), at: .now, runtime: "codex")
        #expect(long.wasTruncated)
        #expect(long.text.count <= 4000 && long.text.utf8.count <= 16_000)
    }
}
