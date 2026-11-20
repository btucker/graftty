import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyCommandUI

struct PinnedTileTests {
    @Test("@spec LAYOUT-2.225: While a pinned agent is shown as a tile, the application shall show an orange dot before its name only while it asks for user input, a pulsing blue dot while it works even if a notification is pending, fade it while its host sleeps, and draw no dot otherwise, including after a turn stops.")
    func tileStates() {
        let busy: PaneLayoutNode = .leaf(sessionName: "agent", title: "Tests", attentionText: nil, isBusy: true, attentionSource: nil)
        let question: PaneLayoutNode = .leaf(sessionName: "question", title: "Agent", attentionText: "Retry?", isBusy: false, attentionSource: .agentStop)
        let idle: PaneLayoutNode = .leaf(sessionName: "idle", title: "Agent", attentionText: nil, isBusy: false, attentionSource: nil)
        #expect(tileState(layout: question) == .waiting)
        #expect(tileState(layout: .split(direction: .horizontal, ratio: 0.5, left: busy, right: question), notice: "Build done") == .waiting)
        #expect(tileState(layout: question, isCached: true) == .asleep)
        #expect(tileState(layout: busy) == .working)
        #expect(tileState(layout: .split(direction: .horizontal, ratio: 0.5, left: busy, right: idle), notice: "Build done").pip == .pulse)
        let notification = tileState(notice: "Build done")
        #expect(notification == .idle)
        #expect(notification.pip == nil)
        #expect(PinnedTile.accessibilityLabel(name: "triage", host: nil, state: notification) == "triage")
        let stop = SidebarAgentStop(agentName: "Agent", stoppedAt: Date(timeIntervalSince1970: 3))
        let finished = tileState(layout: busy, stop: stop)
        #expect(finished == .finished)
        var notice = AttentionRecap(title: "Build", completed: "Build done", next: "Review")
        notice.notice = "Build done"
        #expect(tileState(stop: SidebarAgentStop(agentName: "Agent", stoppedAt: stop.stoppedAt, recap: notice)) == .idle)
        #expect(PinnedTile.accessibilityLabel(name: "appcast", host: nil, state: finished) == "appcast, finished, not yet opened")
        #expect(PinnedTileState.waiting.pip == .filled)
        #expect(PinnedTileState.finished.pip == nil, "A stopped turn draws nothing")
        #expect(PinnedTileState.working.pip == .pulse)
        #expect(PinnedTileState.asleep.pip == nil)
        #expect(PinnedTileState.idle.pip == nil)
    }

    private func tileState(layout: PaneLayoutNode? = nil, notice: String? = nil, stop: SidebarAgentStop? = nil,
                           isCached: Bool = false) -> PinnedTileState {
        let row = WorktreePanes(path: "/w", displayName: "w", repoDisplayName: "app", displayBranch: "w",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: notice,
            attentionSource: notice == nil ? nil : .userNotify, layout: layout,
            sidebar: .init(id: "s", projectID: "p", unseenAgentStop: stop))
        return PinnedTileState.resolve(context: SidebarWorktreeContext(worktree: row), isCached: isCached)
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
