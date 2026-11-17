import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("Sparse worktree context updates")
struct WorktreeContextUpdateTests {
    private let start = Date(timeIntervalSinceReferenceDate: 100)

    private func brief() -> WorktreeBrief {
        WorktreeBrief(recap: .init(title: "Crash investigation", context: "Startup crashes block work.",
            completed: "Reproduced the crash.", next: "Trace restoration.",
            decisions: ["Keep the save format."]), at: start)
    }

    @Test("@spec CONTEXT-64: When an agent submits a current-state update, the application shall replace its summary and optional next step while retaining omitted purpose, identity, decisions, and history.")
    func replacesNowWithoutRepeatingContext() {
        var value = brief()
        value.update(AttentionRecap(update: .init(now: .init(summary: "Fixed restoration."))), at: start.addingTimeInterval(2))
        #expect(value.title == "Crash investigation")
        #expect(value.context == "Startup crashes block work.")
        #expect(value.completed == "Fixed restoration.")
        #expect(value.next.isEmpty)
        #expect(value.decisions == ["Keep the save format."])
        #expect(value.history.isEmpty)
    }

    @Test("@spec CONTEXT-65: When updates to different retained groups arrive out of order, the application shall compare freshness per group and preserve newer values within each group.")
    func freshnessBelongsToEachGroup() throws {
        var value = brief()
        value.update(AttentionRecap(update: .init(now: .init(summary: "Tests passed."))), at: start.addingTimeInterval(4))
        value.update(AttentionRecap(update: .init(purpose: .init(title: "Restore fix", context: "Broken restores block startup."))), at: start.addingTimeInterval(2))
        value.update(AttentionRecap(update: .init(now: .init(summary: "Old progress."))), at: start.addingTimeInterval(3))
        value = try JSONDecoder().decode(WorktreeBrief.self, from: JSONEncoder().encode(value))
        #expect(value.title == "Restore fix")
        #expect(value.completed == "Tests passed.")
        #expect(value.updatedAt == 104)
    }

    @Test("@spec CONTEXT-66: When an agent acknowledges no change or submits only attention, the application shall preserve the retained brief and its content timestamp.")
    func noChangeAndQuestionsDoNotRewriteContext() {
        let original = brief()
        var value = original
        value.update(AttentionRecap(update: .init(unchanged: true)), at: start.addingTimeInterval(2))
        #expect(value == original)
        value.update(AttentionRecap(update: .init(attention: .init(kind: .ask, question: "Ship?"))), at: start.addingTimeInterval(3))
        #expect(value == original)
    }

    @Test("@spec CONTEXT-67: When an agent submits an attention request, the application shall validate asks and notices separately and reject contradictory or empty updates.")
    func validatesIntent() {
        #expect(!WorktreeContextUpdate().isValid)
        #expect(WorktreeContextUpdate(unchanged: true).isValid)
        #expect(!WorktreeContextUpdate(now: .init(summary: " ")).isValid)
        #expect(!WorktreeContextUpdate(now: .init(summary: "Done."), unchanged: true).isValid)
        #expect(WorktreeContextUpdate(attention: .init(kind: .notice, message: "Ready for review.")).isValid)
        #expect(!WorktreeContextUpdate(attention: .init(kind: .notice, question: "Ship?", message: "Ready.")).isValid)
        #expect(!WorktreeContextUpdate(attention: .init(kind: .ask, question: "Ship?", options: [.init(label: "/ship"), .init(label: "Wait")])).isValid)
        var receipt = AttentionRecap(update: .init(unchanged: true))
        receipt.title = String(repeating: "x", count: 101)
        #expect(!receipt.isValid)
    }

    @Test("@spec CONTEXT-68: When a stopped turn carries a notice, the application shall request attention without exposing an answerable question, while routine completion shall remain activity.")
    func noticesAndQuestionsAreDistinct() {
        let notice = SidebarAgentStop(agentName: "Codex", stoppedAt: start,
            recap: AttentionRecap(update: .init(attention: .init(kind: .notice, message: "Ready for review."))))
        #expect(notice.requestsAttention)
        #expect(notice.question == nil)
        #expect(notice.notice == "Ready for review.")
        #expect(!SidebarAgentStop(agentName: "Codex", stoppedAt: start).requestsAttention)
    }

    @Test("@spec CONTEXT-75: When explicit history updates arrive out of order or a receipt is retried after another entry, the application shall retain distinct events in time order and append each receipt at most once.")
    func historyIsAnEventRatherThanAReplaceableGroup() {
        var value = brief()
        let first = AttentionRecap(update: .init(historyEntry: .init(headline: "Found the trigger.")))
        let later = AttentionRecap(update: .init(historyEntry: .init(headline: "Chose the fix.")))
        let delayed = AttentionRecap(update: .init(historyEntry: .init(headline: "Ruled out the cache.")))
        value.update(first, at: start.addingTimeInterval(2))
        value.update(later, at: start.addingTimeInterval(4))
        value.update(delayed, at: start.addingTimeInterval(1))
        value.update(first, at: start.addingTimeInterval(2))
        #expect(value.history.map(\.title) == ["Ruled out the cache.", "Found the trigger.", "Chose the fix."])
        #expect(value.updatedAt == 104)
    }

    @Test func delayedRepeatedHistoryTextKeepsChronologicalSeparator() {
        var value = brief()
        value.update(.init(update: .init(historyEntry: .init(headline: "A"))), at: start.addingTimeInterval(2))
        value.update(.init(update: .init(historyEntry: .init(headline: "B"))), at: start.addingTimeInterval(3))
        let delayed = AttentionRecap(update: .init(historyEntry: .init(headline: "B")))
        value.update(delayed, at: start.addingTimeInterval(1))
        value.update(delayed, at: start.addingTimeInterval(1))
        #expect(value.history.map(\.title) == ["B", "A", "B"])
    }
}
