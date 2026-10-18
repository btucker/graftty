import Foundation
import Testing
@testable import GrafttyProtocol

struct WorktreeBriefTests {
    private let start = Date(timeIntervalSince1970: 100)

    @Test("@spec CONTEXT-1: When an agent updates a worktree report, the application shall retain its purpose title until a report explicitly declares a purpose change, while updating its current context, progress, decisions, and next step.")
    func keepsPurposeUntilExplicitlyChanged() {
        var brief = WorktreeBrief(recap: .init(title: "Worktree context", context: "Help the user resume work.", completed: "Explored options.", next: "Choose a layout.", decisions: ["Use a right drawer."]), at: start)
        brief.update(.init(title: "Tests passed", completed: "Built the drawer.", next: "Review it."), at: start.addingTimeInterval(10))
        #expect(brief.title == "Worktree context")
        #expect(brief.context == "Help the user resume work.")
        #expect(brief.completed == "Built the drawer.")
        #expect(brief.decisions == ["Use a right drawer."])
        brief.update(.init(title: "Native notifications", context: "Deliver agent stops through the OS.", completed: "Changed scope.", next: "Wire delivery.", purposeChanged: true, decisions: []), at: start.addingTimeInterval(20))
        #expect(brief.title == "Native notifications")
        #expect(brief.decisions.isEmpty)
        #expect(brief.context == "Deliver agent stops through the OS.")
        brief.update(.init(title: "Native notifications", context: "Now support suspended devices.",
            completed: "Changed the goal without renaming it.", next: "Configure push.", purposeChanged: true), at: start.addingTimeInterval(30))
        #expect(brief.history.count == 3)
        #expect(brief.title == "Native notifications")
    }

    @Test("@spec CONTEXT-2: When an agent reports a meaningful checkpoint or purpose change, the application shall retain it in the worktree history, merge consecutive updates to the same checkpoint, ignore repeated reports and older updates, and retain at most 32 checkpoints.")
    func retainsMeaningfulEvolution() {
        let initial = AttentionRecap(title: "Worktree context", completed: "Started.", next: "Explore.")
        var brief = WorktreeBrief(recap: initial, at: start)
        brief.update(initial, at: start.addingTimeInterval(1))
        brief.update(.init(title: "Routine update", completed: "Read source.", next: "Explore."), at: start.addingTimeInterval(2))
        #expect(brief.history.count == 1)
        var checkpoint = AttentionRecap(title: "Worktree context", completed: "Picked the brief.", next: "Build.", checkpoint: "Brief with expandable history")
        brief.update(checkpoint, at: start.addingTimeInterval(3))
        checkpoint.completed = "Built the chosen layout."
        brief.update(checkpoint, at: start.addingTimeInterval(4))
        #expect(brief.history.count == 2)
        #expect(brief.history.last?.completed == "Built the chosen layout.")
        brief.update(initial, at: start)
        #expect(brief.completed == "Built the chosen layout.")
        for index in 0..<40 {
            checkpoint.checkpoint = "Milestone \(index)"
            brief.update(checkpoint, at: start.addingTimeInterval(Double(index + 10)))
        }
        #expect(brief.history.count == 32)
        #expect(brief.history.last?.title == "Milestone 39")
    }

    @Test("@spec CONTEXT-3: When a report includes purpose-change, checkpoint, or decision fields, the application shall validate their text bounds and preserve legacy reports that omit those fields.")
    func validatesAndDecodesNewReportFields() throws {
        var recap = AttentionRecap(title: "Context", completed: "Built.", next: "Review.", checkpoint: "Initial layout", decisions: ["Right drawer"])
        #expect(recap.isValid)
        #expect(try JSONDecoder().decode(AttentionRecap.self, from: JSONEncoder().encode(recap)) == recap)
        recap.checkpoint = String(repeating: "x", count: 101)
        #expect(!recap.isValid)
        recap.checkpoint = "Layout"
        recap.decisions = ["\nInvalid"]
        #expect(!recap.isValid)
        recap.decisions = Array(repeating: "Decision", count: 9)
        #expect(!recap.isValid)
        let legacy = try JSONDecoder().decode(AttentionRecap.self, from: Data(#"{"title":"Context","completed":"Built.","next":"Review."}"#.utf8))
        #expect(legacy.isValid)
        #expect(legacy.purposeChanged == nil)
        #expect(legacy.decisions == nil)
    }
}
