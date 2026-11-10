import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct WorktreeActivitySectionsTests {
    private func question(at time: Double) -> SidebarAgentStop {
        .init(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: time),
              recap: .init(title: "Ask", completed: "Done", next: "Next", need: "Which one?"), providerSessionKey: "agent")
    }

    private func worktree(_ name: String, pinned: Bool = false, asked: Double? = nil, unreadStop: Bool = false, busy: Bool = false,
                          activity: Double? = nil, state: WorktreeWireState = .running) -> WorktreePanes {
        let routine = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 1),
                                       recap: .init(title: "Stop", completed: "Finished", next: "Next"))
        return .init(path: "/" + name, displayName: name, repoDisplayName: "app", displayBranch: name, state: state,
                     isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                     layout: busy ? .leaf(sessionName: name + "-pane", title: "Running tests", attentionText: nil, isBusy: true, attentionSource: nil) : nil,
                     sidebar: .init(id: name, projectID: "p", unseenAgentStop: asked.map(question) ?? (unreadStop ? routine : nil),
                                    isPinned: pinned, activityTime: activity))
    }

    private func row(_ worktree: WorktreePanes, availability: HostAvailability = .reachable) -> MergedWorktreeRow {
        let built = MergedWorktreeList.build(rows: [worktree], availability: { _ in availability }, projectIsOnSeveralHosts: false)
        return built.pinned.first ?? built.temporary[0]
    }

    private func make(pinned: [MergedWorktreeRow] = [], temporary: [WorktreePanes] = [],
                      holding hold: WorktreeActivitySections.Hold? = nil, pullsWaitingPins: Bool = true) -> WorktreeActivitySections {
        WorktreeActivitySections.make(pinned: pinned, temporary: temporary.map { row($0) },
                                      context: { SidebarWorktreeContext(worktree: $0) }, holding: hold,
                                      pullsWaitingPins: pullsWaitingPins)
    }

    private func names(_ rows: [MergedWorktreeRow]) -> [String] { rows.map(\.row.displayName) }

    @Test("@spec IOS-13.1: While a worktree list shows a project, the application shall show its pinned agents as tiles, then group its temporary worktrees into Needs you, Working, and Recent, in that order, with Needs you holding rows that ask a question, carry a notification, or finished a turn the user has not opened, newest first.")
    func groupsRowsByWhatTheyWant() {
        let sections = make(temporary: [
            worktree("older-question", asked: 10, activity: 90), worktree("newer-question", asked: 20, activity: 80),
            worktree("running", busy: true, activity: 70), worktree("quiet", activity: 60),
        ], pullsWaitingPins: false)
        #expect(names(sections.needsYou) == ["newer-question", "older-question"])
        #expect(names(sections.working) == ["running"])
        #expect(names(sections.recent) == ["quiet"])
        #expect(sections.pinned.isEmpty)
    }

    @Test("@spec IOS-13.2: While a pinned worktree waits for the user, the application shall keep its tile in its pinned place in that project's list rather than also listing it under Needs you.")
    func waitingPinnedRowStaysInPlace() {
        let pins = [row(worktree("a", pinned: true)), row(worktree("b", pinned: true, asked: 5)), row(worktree("c", pinned: true, unreadStop: true))]
        let sections = make(pinned: pins, pullsWaitingPins: false)
        #expect(sections.needsYou.isEmpty)
        #expect(names(sections.pinned) == ["a", "b", "c"])
    }

    /// The Projects screen lists everything waiting across projects and has no tiles.
    @Test func listsAcrossProjectsStillPullWaitingPins() {
        let sections = make(pinned: [row(worktree("a", pinned: true)), row(worktree("b", pinned: true, asked: 5))])
        #expect(names(sections.needsYou) == ["b"])
        #expect(names(sections.pinned) == ["a"])
    }

    @Test("@spec IOS-13.3: While a pinned worktree has a working agent, the application shall keep it in Pinned, so Working holds only temporary worktrees.")
    func workingPinnedRowStaysPinned() {
        let sections = make(pinned: [row(worktree("a", pinned: true, busy: true))], pullsWaitingPins: false)
        #expect(names(sections.pinned) == ["a"])
        #expect(sections.working.isEmpty)
    }

    @Test("@spec IOS-13.4: While a temporary worktree has a finished turn the user has not opened, the application shall list it under Needs you, and list a finished turn that asks a question there once.")
    func unreadStopGoesToNeedsYou() {
        let sections = make(temporary: [worktree("a", unreadStop: true, activity: 5), worktree("b", asked: 9, activity: 4)])
        #expect(names(sections.needsYou) == ["b", "a"])
        #expect(sections.recent.isEmpty)
    }

    /// An agent can stop without ever sending a recap; it still waits for the user.
    @Test func unreadStopWithoutARecapStillNeedsYou() {
        let bare = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 3), recap: nil)
        let row = WorktreePanes(path: "/bare", displayName: "bare", repoDisplayName: "app", displayBranch: "bare", state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "bare", projectID: "p", unseenAgentStop: bare))
        let sections = make(temporary: [row])
        #expect(names(sections.needsYou) == ["bare"])
        #expect(SidebarRowStatus.resolve(context: SidebarWorktreeContext(worktree: row), worktree: row, isCached: false)
            == .whereWeAre("Codex stopped", isUnread: true))
    }

    @Test("@spec IOS-13.5: While a worktree is being created, the application shall list it under Working so it stays near the top of the list.")
    func creatingRowCountsAsWorking() {
        let sections = make(temporary: [worktree("old", activity: 5), worktree("new", state: .creating)])
        #expect(names(sections.working) == ["new"])
    }

    @Test("@spec IOS-13.6: While a row comes from a sleeping host, the application shall list it under Recent rather than Needs you or Working, because its last report says nothing about what is happening now.")
    func sleepingRowsStayInRecent() {
        let asleep = [worktree("asked", asked: 5), worktree("busy", busy: true)].map { row($0, availability: .wakeable) }
        let sections = WorktreeActivitySections.make(pinned: [], temporary: asleep,
            context: { SidebarWorktreeContext(worktree: $0) }, holding: nil)
        #expect(names(sections.recent) == ["asked", "busy"])
    }

    @Test("@spec IOS-13.7: While the user is touching or editing a mobile worktree list or a row's report is open, the application shall keep each row in its section and position, then apply any changes on release.")
    func holdKeepsRowsInPlaceAndCarriesLiveContent() {
        let before = make(temporary: [worktree("a", asked: 10, activity: 3), worktree("b", asked: 20, activity: 2), worktree("c", activity: 1)])
        #expect(names(before.needsYou) == ["b", "a"])
        // While held: a newer question on a, c starts asking, and b is answered.
        let current = [worktree("d", activity: 9), worktree("a", asked: 30, activity: 3), worktree("b", activity: 2), worktree("c", asked: 40, activity: 1)]
        let held = make(temporary: current, holding: before.hold)
        #expect(names(held.needsYou) == ["b", "a"])
        #expect(names(held.recent) == ["c", "d"])
        #expect(held.needsYou[1].row.sidebar?.unseenAgentStop?.timestamp == 30)
        let released = make(temporary: current)
        #expect(names(released.needsYou) == ["c", "a"])
        #expect(names(released.recent) == ["d", "b"])
    }

    @Test func holdDropsRowsThatLeftAndIgnoresAPinChange() {
        let before = make(pinned: [row(worktree("a", pinned: true))], temporary: [worktree("b", activity: 1), worktree("c")])
        // a was unpinned elsewhere, b was pinned elsewhere, and c is gone.
        let held = make(pinned: [row(worktree("b", pinned: true))], temporary: [worktree("a", activity: 1)], holding: before.hold)
        #expect(names(held.pinned) == ["b"])
        #expect(names(held.recent) == ["a"])
    }

    @Test("@spec IOS-13.8: While a mobile worktree row has a known time, the application shall state how long ago it asked or was last active in one compact unit, and otherwise shall show no time.", arguments: [
        (0.0, "now"), (59.0, "now"), (60.0, "1m"), (3599.0, "59m"), (3600.0, "1h"), (86399.0, "23h"),
        (86400.0, "1d"), (604799.0, "6d"), (604800.0, "1w"), (-500.0, "now"),
    ] as [(Double, String)])
    func rowTime(age: Double, expected: String) {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(WorktreeActivitySections.ageText(since: now.addingTimeInterval(-age), now: now) == expected)
    }

    /// A row's time comes off the wire, and a trap here would take the whole list down.
    @Test(arguments: [1e300, -1e300])
    func rowTimeSurvivesAnOutOfRangeTimestamp(timestamp: Double) {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let text = WorktreeActivitySections.ageText(since: Date(timeIntervalSinceReferenceDate: timestamp), now: now)
        #expect(!text.isEmpty)
    }

    @Test("@spec IOS-13.9: While the compact Projects screen has worktrees needing the user across projects, the application shall list them above the project list, showing two with a control for the rest until it is used.")
    func projectsScreenPreview() {
        let rows = ["a", "b", "c"].map { row(worktree($0)) }
        #expect(WorktreeActivitySections.preview(rows, showsAll: false).rows.count == 2)
        #expect(WorktreeActivitySections.preview(rows, showsAll: false).hidden == 1)
        #expect(WorktreeActivitySections.preview(rows, showsAll: true).rows.count == 3)
        #expect(WorktreeActivitySections.preview(rows, showsAll: true).hidden == 0)
        #expect(WorktreeActivitySections.preview(Array(rows.prefix(1)), showsAll: false).hidden == 0)
    }

    @Test func rowDateIsWhenItAskedOtherwiseItsActivity() {
        let asked = worktree("a", asked: 50, activity: 10)
        #expect(WorktreeActivitySections.rowDate(asked, context: SidebarWorktreeContext(worktree: asked))?.timeIntervalSinceReferenceDate == 50)
        let quiet = worktree("b", activity: 10)
        #expect(WorktreeActivitySections.rowDate(quiet, context: SidebarWorktreeContext(worktree: quiet))?.timeIntervalSinceReferenceDate == 10)
        let unknown = worktree("c")
        #expect(WorktreeActivitySections.rowDate(unknown, context: SidebarWorktreeContext(worktree: unknown)) == nil)
    }
}

struct WorktreeActivitySectionPlacementTests {
    private func row(_ name: String) -> MergedWorktreeRow {
        MergedWorktreeList.build(rows: [WorktreePanes(path: "/\(name)", displayName: name, repoDisplayName: "app", displayBranch: name, state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)],
            availability: { _ in .reachable }, projectIsOnSeveralHosts: false).temporary[0]
    }

    @Test("@spec LAYOUT-2.212: While the Mac sidebar shows a project, the application shall keep its pinned tiles above the list and show Needs you, Working, and Recent in the list below them.")
    func tilesAboveTheListOfTemporaryWorktrees() {
        var sections = WorktreeActivitySections()
        sections.needsYou = [row("asking")]
        sections.pinned = [row("pinned")]
        sections.working = [row("working")]
        sections.recent = [row("recent")]
        let top = sections.placed(in: .pinned)
        #expect(top.pinned.map(\.row.displayName) == ["pinned"])
        #expect(top.needsYou.isEmpty && top.working.isEmpty && top.recent.isEmpty)
        let below = sections.placed(in: .tasks)
        #expect(below.pinned.isEmpty)
        #expect(below.needsYou.map(\.row.displayName) == ["asking"])
        #expect(below.working.map(\.row.displayName) == ["working"])
        #expect(below.recent.map(\.row.displayName) == ["recent"])
        #expect(sections.placed(in: .all) == sections)
    }
}
