import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec CONTEXT-40: When a provider emits a visible agent response, the application shall retain it once in worktree history independently of attention, order it between human inputs and other events by its original time, and show its wrapping summary with the original text available on expansion on Mac and mobile.")
struct WorktreeAgentResponseTests {
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
