import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec CONTEXT-30: When the application locates timeline messages in an agent terminal's scrollback, it shall match a whitespace-insensitive prefix of each message's first non-empty line after stripping terminal prompt and border glyphs, assign rows in chronological order using the latest consistent copy when resize redraws duplicate the transcript, require a whole-row match for messages too short to be distinctive, and leave a message without a row when it is absent.")
struct ScrollbackMapTests {
    private func input(_ id: String, _ text: String) -> ScrollbackMap.Message { .init(eventID: id, kind: .input, text: text) }
    private func peer(_ id: String, _ text: String) -> ScrollbackMap.Message { .init(eventID: id, kind: .peer, text: text) }

    @Test func locatesMessagesBehindPromptAndBorderGlyphs() {
        let rows = [
            "$ claude",
            "╭──────────────────────────╮",
            "│ >  Please   fix the sidebar layout │",
            "╰──────────────────────────╯",
            "⏺ I will look at the sidebar.",
            "› <graftty-peer-message agent=\"/repo/a#claude\">Checked the",
            "  layout and kept the full investigation.",
        ]
        let map = ScrollbackMap.locate([input("a", "Please fix the sidebar layout"),
                                        peer("b", "Checked the layout and kept the full investigation.")],
                                       rows: rows, firstRow: 100, totalRows: 140)
        #expect(map.totalRows == 140)
        #expect(map.marks == [.init(row: 102, kind: .input, eventID: "a"), .init(row: 105, kind: .peer, eventID: "b")])
        #expect(map.row(for: "b") == 105)
        #expect(map.row(for: "missing") == nil)
    }

    @Test func matchesAPrefixOfTheFirstNonEmptyLineAcrossWrappedRows() {
        let long = "Investigate why the worktree context panel duplicates rows after resizing the window and fix it"
        let rows = ["unrelated", "> Investigate why the worktree co", "ntext panel duplicates rows after", "resizing"]
        let map = ScrollbackMap.locate([input("a", "\n\n  " + long + "\nSecond line that never appears.")], rows: rows)
        #expect(map.marks.map(\.row) == [1])
        #expect(map.totalRows == rows.count)
    }

    @Test func prefersTheLatestConsistentCopyAfterResizeRedraws() {
        let rows = [
            "> Start the migration plan", "⏺ ok", "> Now verify the mobile drawer",   // copy at old width
            "> Start the migration plan", "⏺ ok", "> Now verify the mobile drawer",   // redraw at new width
            "> Ship it after the checks pass",
        ]
        let map = ScrollbackMap.locate([input("1", "Start the migration plan"), input("2", "Now verify the mobile drawer"),
                                        input("3", "Ship it after the checks pass")], rows: rows)
        #expect(map.marks.map(\.row) == [3, 5, 6])
    }

    @Test func assignsRepeatedMessagesDistinctOrderedRows() {
        let rows = ["› Short peer status update.", "⏺ noted", "› Short peer status update.", "⏺ noted"]
        let map = ScrollbackMap.locate([peer("1", "Short peer status update."), peer("2", "Short peer status update.")], rows: rows)
        #expect(map.marks.map(\.row) == [0, 2])
        #expect(map.marks.map(\.eventID) == ["1", "2"])
    }

    @Test func leavesAbsentAndOutOfOrderMessagesUnlocated() {
        let rows = ["> The second request is here", "> The first request comes later"]
        let map = ScrollbackMap.locate([input("1", "The first request comes later"), input("2", "The second request is here"),
                                        input("3", "Never typed into this terminal")], rows: rows)
        // Rows stay monotonic in chronological order; no row is invented for the rest.
        #expect(map.marks.count == 1)
        #expect(map.row(for: "3") == nil)
        #expect(ScrollbackMap.locate([input("1", "   \n  ")], rows: ["> "]).marks.isEmpty)
    }

    @Test func requiresAWholeRowMatchForShortMessages() {
        let rows = ["⏺ That looks ok to me, shipping.", "> ok", "⏺ Done."]
        #expect(ScrollbackMap.locate([input("1", "ok")], rows: rows).marks.map(\.row) == [1])
        #expect(ScrollbackMap.locate([input("1", "ok")], rows: ["⏺ That looks ok to me"]).marks.isEmpty)
    }

    @Test func findsTheNearestMarkToARow() {
        let map = ScrollbackMap(totalRows: 100, marks: [.init(row: 10, kind: .input, eventID: "a"),
                                                       .init(row: 40, kind: .peer, eventID: "b")])
        #expect(map.nearestMark(toRow: 0)?.eventID == "a")
        #expect(map.nearestMark(toRow: 24)?.eventID == "a")
        #expect(map.nearestMark(toRow: 26)?.eventID == "b")
        #expect(map.nearestMark(toRow: 99)?.eventID == "b")
        #expect(ScrollbackMap(totalRows: 5, marks: []).nearestMark(toRow: 2) == nil)
    }

    @Test func extractsHumanInputAndPeerMessagesFromTheTimeline() {
        var history = WorktreeHistory(origin: .init(date: Date(timeIntervalSince1970: 50), source: .user))
        history.record(.init(text: "Fix the layout.", at: Date(timeIntervalSince1970: 100)))
        history.record(.init(text: "<graftty-peer-message agent=\"/repo/a#claude\">Checked.</graftty-peer-message>",
                             at: Date(timeIntervalSince1970: 200)))
        let timeline = WorktreeTimeline(history: history, brief: nil)
        let messages = ScrollbackMap.messages(in: timeline)
        #expect(messages.map(\.kind) == [.input, .peer])
        #expect(messages.map(\.text) == ["Fix the layout.", "Checked."])
        #expect(messages.map(\.eventID) == timeline.events.filter { $0.kind == .user || $0.kind == .agentMessage }.map(\.id))
    }
}
