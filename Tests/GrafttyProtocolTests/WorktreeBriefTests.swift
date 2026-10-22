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
        #expect(brief.history.count == 2)
        #expect(brief.title == "Native notifications")
    }

    @Test("@spec CONTEXT-2: When an agent reports a legacy checkpoint or purpose change, the application shall retain it without copying accumulated decisions, merge consecutive updates to the same legacy checkpoint, ignore repeated reports and older updates, retain at most 32 entries, and leave routine reports out of history.")
    func retainsMeaningfulEvolution() {
        let initial = AttentionRecap(title: "Worktree context", completed: "Started.", next: "Explore.")
        var brief = WorktreeBrief(recap: initial, at: start)
        brief.update(initial, at: start.addingTimeInterval(1))
        brief.update(.init(title: "Routine update", completed: "Read source.", next: "Explore."), at: start.addingTimeInterval(2))
        #expect(brief.history.isEmpty)
        var checkpoint = AttentionRecap(title: "Worktree context", completed: "Picked the brief.", next: "Build.", checkpoint: "Brief with expandable history")
        brief.update(checkpoint, at: start.addingTimeInterval(3))
        checkpoint.completed = "Built the chosen layout."
        brief.update(checkpoint, at: start.addingTimeInterval(4))
        #expect(brief.history.count == 1)
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

    @Test("@spec CONTEXT-23: When a report includes an explicit history entry, the application shall retain its headline and optional detail independently of the current brief, suppress consecutive identical entries without moving their timestamps, and preserve distinct entries and entries separated by user input.")
    func explicitEntriesAreIndependentOfStatus() throws {
        let data = Data(#"{"title":"Context history","context":"Remember how we got here.","completed":"Read the code.","next":"Implement.","decisions":["Support both platforms"],"checkpoint":"Old cached instruction","historyEntry":{"headline":"Snapshots repeat decisions.","detail":"Each checkpoint copies the complete decision list."}}"#.utf8)
        var recap = try JSONDecoder().decode(AttentionRecap.self, from: data)
        var brief = WorktreeBrief(recap: recap, at: start)
        #expect(brief.history.count == 1)
        #expect(brief.history.first?.title == "Snapshots repeat decisions.")
        #expect(brief.history.first?.completed == "Each checkpoint copies the complete decision list.")
        #expect(brief.history.first?.decisions == [])
        let original = brief.history.first
        recap.completed = "Implementation started."
        recap.next = "Run tests."
        recap.decisions = ["Support both platforms", "Keep source text"]
        brief.update(recap, at: start.addingTimeInterval(10))
        #expect(brief.history.first == original)
        #expect(brief.history.count == 1)
        #expect(brief.completed == "Implementation started.")
        #expect(brief.decisions.count == 2)
        brief.update(recap, at: start.addingTimeInterval(30), preservingCheckpointBefore: start.addingTimeInterval(20))
        #expect(brief.history.count == 2)
        #expect(try JSONDecoder().decode(WorktreeBrief.self, from: JSONEncoder().encode(brief)) == brief)
        let different = try JSONDecoder().decode(AttentionRecap.self, from: Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "Each checkpoint copies the complete decision list.", with: "A new finding with the same headline.").utf8))
        brief.update(different, at: start.addingTimeInterval(40))
        #expect(brief.history.count == 3)
        brief.update(recap, at: start) // Delayed delivery cannot overwrite newer work.
        #expect(brief.history.count == 3)
    }

    @Test func legacyPurposeChangesKeepTheirAuthoredCheckpointAndIgnoreReplays() {
        var brief = WorktreeBrief(recap: .init(title: "Context", context: "Remember the work", completed: "Started", next: "Explore"), at: start)
        let recap = AttentionRecap(title: "Notifications", context: "Deliver agent stops", completed: "Chose push delivery", next: "Implement",
                                   purposeChanged: true, checkpoint: "Push chosen")
        brief.update(recap, at: start.addingTimeInterval(10))
        #expect(brief.history.count == 1)
        #expect(brief.history.first?.title == "Push chosen")
        #expect(brief.history.first?.completed == "Chose push delivery")
        let history = brief.history
        brief.update(recap, at: start.addingTimeInterval(20))
        #expect(brief.history == history)
    }

    @Test func updatingSavedLegacyCheckpointPreservesItsDecisions() throws {
        let recap = AttentionRecap(title: "Context", completed: "Picked a layout", next: "Build", checkpoint: "Layout chosen")
        let brief = WorktreeBrief(recap: recap, at: start)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(brief)) as? [String: Any])
        var snapshots = try #require(object["history"] as? [[String: Any]])
        snapshots[0]["decisions"] = ["Keep source text"]
        object["history"] = snapshots
        var restored = try JSONDecoder().decode(WorktreeBrief.self, from: JSONSerialization.data(withJSONObject: object))
        restored.update(.init(title: "Context", completed: "Built the chosen layout", next: "Verify", checkpoint: "Layout chosen"),
                        at: start.addingTimeInterval(10))
        #expect(restored.history.count == 1)
        #expect(restored.history.first?.completed == "Built the chosen layout")
        #expect(restored.history.first?.decisions == ["Keep source text"])
    }

    @Test func routineUpdatesDoNotRewriteHistoryAndExplicitEntriesStayBounded() {
        var brief = WorktreeBrief(recap: .init(title: "Context", completed: "Started", next: "Explore"), at: start)
        for index in 0..<40 {
            brief.update(.init(title: "Context", completed: "Status", next: "Review",
                historyEntry: .init(headline: "Finding \(index)")), at: start.addingTimeInterval(Double(index + 1)))
        }
        #expect(brief.history.count == 32)
        #expect(brief.history.first?.title == "Finding 8")
        let history = brief.history
        brief.update(.init(title: "Context", completed: "More routine progress", next: "Review", decisions: ["Keep originals"]),
                     at: start.addingTimeInterval(50))
        #expect(brief.history == history)
        #expect(brief.decisions == ["Keep originals"])
    }

    @Test func historyEntryValidation() throws {
        for (entry, valid) in [
            (["headline": "Changed direction."], true),
            (["headline": String(repeating: "h", count: 160), "detail": String(repeating: "d", count: 300)], true),
            (["headline": " "], false),
            (["headline": String(repeating: "h", count: 161)], false),
            (["headline": "Changed", "detail": ""], false),
            (["headline": "Changed", "detail": "Invalid\ntext"], false),
            (["headline": "Changed", "detail": String(repeating: "d", count: 301)], false)
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["title": "Context", "completed": "Done", "next": "Review", "historyEntry": entry])
            let recap = try JSONDecoder().decode(AttentionRecap.self, from: data)
            #expect(recap.isValid == valid)
            #expect(try JSONDecoder().decode(AttentionRecap.self, from: JSONEncoder().encode(recap)) == recap)
        }
    }

    @Test("@spec CONTEXT-3: When a report includes purpose-change, checkpoint, history-entry, or decision fields, the application shall validate their text bounds and preserve legacy reports that omit those fields.")
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
