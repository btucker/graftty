import Foundation
import Testing
@testable import GrafttyProtocol

struct WorktreeHistoryTests {
    private let start = Date(timeIntervalSince1970: 100)

    @Test("@spec CONTEXT-12: When a worktree creation is recorded, the application shall retain its timestamp and distinguish human UI creation from creation in another worktree, without inferring an unknown creator from the Git base branch.")
    func creationIsFirstAndUnknownOriginsStayUnknown() throws {
        let origin = WorktreeHistory.Origin(date: start, source: .worktree, worktreePath: "/repo/main", worktreeName: "main")
        let history = WorktreeHistory(origin: origin)
        let timeline = WorktreeTimeline(history: history, brief: brief(count: 2))
        #expect(timeline.events.first?.kind == .creation)
        #expect(timeline.events.first?.title == "Created from main")
        #expect(timeline.events.first?.sourceWorktreePath == "/repo/main")
        #expect(timeline.events.first?.timestamp == start.timeIntervalSinceReferenceDate)
        let user = WorktreeTimeline(history: .init(origin: .init(date: start, source: .user)), brief: nil)
        #expect(user.events.first?.title == "Created by you")
        let unknown = WorktreeTimeline(history: .init(origin: .init(date: start, source: .unknown)), brief: nil)
        #expect(unknown.events.first?.title == "Worktree created")
        #expect(unknown.events.first?.sourceWorktreePath == nil)
        #expect(WorktreeTimeline(history: nil, brief: nil).events.isEmpty)
        #expect(try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history)) == history)
    }

    @Test("@spec CONTEXT-14: While a worktree history has more than eight events, the application shall fold only consecutive runs of at least two older agent checkpoints, retain creation, every user input, and the latest two checkpoints, and expand each run or all events in chronological order.")
    func foldsOnlyOlderAgentRuns() throws {
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        let input = WorktreeHistory.UserInput(text: "yes", at: start.addingTimeInterval(35))
        history.record(input)
        history.record(input) // Replaying a handoff must not duplicate the reply.
        let timeline = WorktreeTimeline(history: history, brief: brief(count: 10))
        #expect(timeline.events.count == 12)
        #expect(timeline.events.filter { $0.kind == .user }.count == 1)
        let eventTimestamps: [Double?] = timeline.events.filter { $0.kind != .creation }.map(\.timestamp)
        let sortedTimestamps = eventTimestamps.sorted { ($0 ?? 0) < ($1 ?? 0) }
        #expect(eventTimestamps == sortedTimestamps)
        let rows = timeline.rows(showAll: false)
        #expect(rows.map(\.events.count) == [1, 4, 1, 4, 1, 1])
        #expect(rows.filter(\.isGroup).allSatisfy { $0.events.allSatisfy { $0.kind == .checkpoint } })
        #expect(rows.flatMap(\.events) == timeline.events)
        #expect(timeline.rows(showAll: true).count == timeline.events.count)
        #expect(rows.suffix(2).allSatisfy { !$0.isGroup })
        let short = WorktreeTimeline(history: history, brief: brief(count: 3))
        #expect(short.rows(showAll: false).allSatisfy { !$0.isGroup })
        #expect(try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history)) == history)
    }

    @Test func inputRemainsChronologicalAndBounded() {
        var history = WorktreeHistory()
        let late = WorktreeHistory.UserInput(text: "Later", at: start.addingTimeInterval(10))
        history.record(late)
        history.record(.init(text: "Earlier", at: start))
        #expect(history.inputs.map(\.text) == ["Earlier", "Later"])
        let long = WorktreeHistory.UserInput(text: String(repeating: "x", count: 5000), at: start)
        #expect(long.text.count == 2000)
        #expect(long.wasTruncated)
        let emoji = WorktreeHistory.UserInput(text: String(repeating: "👨‍👩‍👧‍👦", count: 2000), at: start)
        #expect(emoji.text.utf8.count <= 8000)
        #expect(emoji.wasTruncated)
        #expect(!emoji.text.contains("�"))
    }

    @Test func userInputSeparatesRepeatedCheckpointHeadings() {
        var brief = brief(count: 1)
        brief.update(.init(title: "Context", completed: "After your reply", next: "Verify", checkpoint: "Step 0"),
            at: start.addingTimeInterval(20), preservingCheckpointBefore: start.addingTimeInterval(10))
        #expect(brief.history.count == 2)
        #expect(brief.history.first?.completed == "Progress 0")
    }

    private func brief(count: Int) -> WorktreeBrief {
        var value = WorktreeBrief(recap: .init(title: "Context", completed: "Progress 0", next: "Next", checkpoint: "Step 0"), at: start)
        for index in 1..<count {
            value.update(.init(title: "Context", completed: "Progress \(index)", next: "Next", checkpoint: "Step \(index)"), at: start.addingTimeInterval(Double(index * 10)))
        }
        return value
    }
}
