import Foundation
import Testing
@testable import GrafttyCommandUI

struct PinnedTileTests {
    @Test("@spec LAYOUT-2.225: While a pinned agent is shown as a tile, the application shall mark it as waiting when it asks a question, carries a notification, or finished a turn the user has not opened, as working while an agent works, as asleep while its host sleeps, and as idle otherwise.")
    func tileStates() {
        #expect(PinnedTileState.resolve(status: .question("q", paneID: nil), isCached: false) == .waiting)
        #expect(PinnedTileState.resolve(status: .notification("n", paneID: nil), isCached: false) == .waiting)
        #expect(PinnedTileState.resolve(status: .whereWeAre("done", isUnread: true), isCached: false) == .waiting)
        #expect(PinnedTileState.resolve(status: .working("tests"), isCached: false) == .working)
        #expect(PinnedTileState.resolve(status: .whereWeAre("done", isUnread: false), isCached: false) == .idle)
        #expect(PinnedTileState.resolve(status: .none, isCached: false) == .idle)
        // A sleeping host's report is old news, even if it once asked.
        #expect(PinnedTileState.resolve(status: .whereWeAre("done", isUnread: true), isCached: true) == .asleep)
    }

    @Test("@spec LAYOUT-2.226: While a pinned agent is shown as a tile, the application shall caption it with the first part of its worktree name, split at hyphens, underscores, slashes, and spaces, or with the branch name for the default checkout.", arguments: [
        ("crash-report", false, "x", "crash"), ("ci_watch", false, "x", "ci"), ("research/notes", false, "x", "research"),
        ("release loop", false, "x", "release"), ("triage", false, "x", "triage"), ("-odd", false, "x", "odd"),
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

    @Test func accessibilityLabelNamesHostAndState() {
        #expect(PinnedTile.accessibilityLabel(name: "crash-report", host: "studio", state: .waiting) == "crash-report, on studio, waiting for you")
        #expect(PinnedTile.accessibilityLabel(name: "triage", host: nil, state: .idle) == "triage")
    }
}
