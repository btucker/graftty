import Foundation
import Testing
@testable import GrafttyCommandUI

struct PinnedTileTests {
    @Test("@spec LAYOUT-2.225: While a pinned agent is shown as a tile, the application shall show an orange dot before its name only while it asks for user input, a pulsing blue dot while its status is working, fade it while its host sleeps, and draw no mark otherwise, including for notifications and stopped turns.")
    func tileStates() {
        #expect(PinnedTileState.resolve(status: .question("q", paneID: nil), isCached: false) == .waiting)
        for paneID: String? in [nil, "agent"] {
            let notification = PinnedTileState.resolve(status: .notification("n", paneID: paneID), isCached: false)
            #expect(notification == .idle)
            #expect(notification.pip == nil)
            #expect(PinnedTile.accessibilityLabel(name: "triage", host: nil, state: notification) == "triage")
        }
        let completed = SidebarRowStatus.whereWeAre("done", isUnread: true)
        let finished = PinnedTileState.resolve(status: completed, isCached: false)
        #expect(finished == .finished)
        #expect(!completed.needsAttention)
        #expect(!completed.waitsForUser)
        #expect(PinnedTile.accessibilityLabel(name: "appcast", host: nil, state: finished) == "appcast, finished, not yet opened")
        #expect(PinnedTileState.resolve(status: .working("tests"), isCached: false) == .working)
        #expect(PinnedTileState.resolve(status: .whereWeAre("done", isUnread: false), isCached: false) == .idle)
        #expect(PinnedTileState.resolve(status: .none, isCached: false) == .idle)
        // A sleeping host's report is old news, even if it once asked.
        #expect(PinnedTileState.resolve(status: .whereWeAre("done", isUnread: true), isCached: true) == .asleep)
        #expect(PinnedTileState.resolve(status: .question("q", paneID: nil), isCached: true) == .asleep)
        // One small cue per tile, never a frame.
        #expect(PinnedTileState.waiting.pip == .filled)
        #expect(PinnedTileState.finished.pip == nil, "A stopped turn draws nothing")
        #expect(PinnedTileState.working.pip == .pulse)
        #expect(PinnedTileState.asleep.pip == nil)
        #expect(PinnedTileState.idle.pip == nil)
    }

    @Test("@spec LAYOUT-2.226: While a pinned agent is shown as a tile, the application shall caption it with its whole worktree name, or the branch name for the default checkout, on one line, ending in an ellipsis only when the name is wider than the tile.", arguments: [
        ("crash-report", false, "x", "crash-report"), ("ci_watch", false, "x", "ci_watch"), ("research/notes", false, "x", "research/notes"),
        ("release loop", false, "x", "release loop"), ("triage", false, "x", "triage"),
        ("graftty", true, "main", "main"),
    ] as [(String, Bool, String, String)])
    func tileWord(name: String, isMainCheckout: Bool, branch: String, expected: String) {
        #expect(PinnedTile.word(name: name, isMainCheckout: isMainCheckout, branch: branch) == expected)
    }

    @Test("@spec LAYOUT-2.228: When the pointer rests on a pinned tile on Mac, the application shall show the worktree's full name, its host when it has one, and the status line its row would show, including an agent's question.")
    func hoverTextNamesTheTileAndItsStatus() {
        #expect(PinnedTile.hoverText(name: "crash-report", host: "studio", status: .question("Retry?", paneID: nil))
            == "crash-report · studio\nNeeds your input: Retry?")
        #expect(PinnedTile.hoverText(name: "triage", host: nil, status: .working("Running tests")) == "triage\nRunning tests")
        #expect(PinnedTile.hoverText(name: "main", host: nil, status: .none) == "main")
    }

    /// Two tiles must not show the same word: the clashing ones use the first
    /// part of their names that differs.
    @Test func captionsKeepWholeNamesSoOnlyTrueDuplicatesClash() {
        let words = PinnedTile.words(for: [
            .init(name: "analytics-dashboard", isMainCheckout: false, branch: "x"),
            .init(name: "analytics-api", isMainCheckout: false, branch: "x"),
            .init(name: "app", isMainCheckout: true, branch: "main"),
            .init(name: "app", isMainCheckout: true, branch: "main"),
        ])
        #expect(words == ["analytics-dashboard", "analytics-api", "main", "main"])
    }

    @Test func accessibilityLabelNamesHostAndState() {
        #expect(PinnedTile.accessibilityLabel(name: "crash-report", host: "studio", state: .waiting) == "crash-report, on studio, waiting for you")
        #expect(PinnedTile.accessibilityLabel(name: "triage", host: nil, state: .idle) == "triage")
        #expect(PinnedTile.accessibilityLabel(name: "appcast", host: nil, state: .finished) == "appcast, finished, not yet opened")
    }
}
