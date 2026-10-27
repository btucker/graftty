import Testing
@testable import GrafttyCommandUI

struct TimelineFollowTests {
    @Test("@spec CONTEXT-28: When a new event arrives in the Context timeline, the application shall scroll to it only while the reader is at the bottom of the timeline, and otherwise shall show a Jump to latest control that scrolls to the latest event and disappears when used or when the reader returns to the bottom.")
    func followsOnlyAtBottomOtherwiseOffersJump() {
        var follow = TimelineFollow()
        #expect(follow.isAtBottom)
        #expect(follow.receivedEvent() == true, "At the bottom, a new event scrolls into view")
        #expect(!follow.showsJumpToLatest)

        follow.scrolled(distanceFromBottom: 25, panelHeight: 800)
        #expect(follow.receivedEvent() == false, "Scrolled away, a new event must not move the reader")
        #expect(follow.showsJumpToLatest)
        #expect(follow.receivedEvent() == false)
        #expect(follow.showsJumpToLatest)

        follow.jumpToLatest()
        #expect(!follow.showsJumpToLatest)
        #expect(follow.isAtBottom)
        #expect(follow.receivedEvent() == true)

        follow.scrolled(distanceFromBottom: 25, panelHeight: 800)
        _ = follow.receivedEvent()
        follow.scrolled(distanceFromBottom: 24, panelHeight: 800)
        #expect(!follow.showsJumpToLatest, "Returning to the bottom by hand clears the pill")
    }

    @Test(arguments: [
        (content: 1000.0, offset: 600.0, visible: 400.0, expected: true),
        (content: 1000.0, offset: 590.0, visible: 400.0, expected: true),
        (content: 1000.0, offset: 500.0, visible: 400.0, expected: false),
        (content: 0.0, offset: 300.0, visible: 400.0, expected: true),
        (content: 200.0, offset: 0.0, visible: 400.0, expected: true),
    ])
    func atBottomFromScrollGeometry(content: Double, offset: Double, visible: Double, expected: Bool) {
        var follow = TimelineFollow()
        follow.scrolled(distanceFromBottom: TimelineFollow.distanceFromBottom(contentHeight: content, offsetY: offset,
            visibleHeight: visible), panelHeight: 800)
        #expect(follow.isAtBottom == expected)
    }

    @Test("@spec CONTEXT-29: When the mobile Context drawer timeline is scrolled more than half the panel height away from the latest event, the application shall collapse the pinned brief to a one-line bar showing the title with the next step, or the pending question when one is waiting, shall expand the full brief when the bar is tapped, and shall restore the full brief only when the bar is tapped or the reader returns to the bottom, so that the brief changing size cannot toggle it back.")
    func mobileBriefCollapsesWhileScrolledAway() {
        let far = 1000.0, panel = 800.0
        var mobile = TimelineFollow(collapsesBrief: true)
        #expect(!mobile.showsCollapsedBrief)
        mobile.scrolled(distanceFromBottom: panel / 2 + 24, panelHeight: panel)
        #expect(!mobile.showsCollapsedBrief, "Within half the panel of the bottom, the brief stays expanded")
        mobile.scrolled(distanceFromBottom: panel / 2 + 25, panelHeight: panel)
        #expect(mobile.showsCollapsedBrief)
        mobile.scrolled(distanceFromBottom: 25, panelHeight: panel)
        #expect(mobile.showsCollapsedBrief, "Only the bottom restores a collapsed brief")
        mobile.expandBrief()
        #expect(!mobile.showsCollapsedBrief)
        mobile.scrolled(distanceFromBottom: far, panelHeight: panel)
        #expect(!mobile.showsCollapsedBrief, "An expanded brief stays expanded while the reader keeps scrolling")
        mobile.scrolled(distanceFromBottom: 24, panelHeight: panel)
        #expect(!mobile.showsCollapsedBrief)
        mobile.scrolled(distanceFromBottom: far, panelHeight: panel)
        #expect(mobile.showsCollapsedBrief, "Returning to the bottom resets the expansion")
        mobile.jumpToLatest()
        #expect(!mobile.showsCollapsedBrief)

        var mac = TimelineFollow()
        mac.scrolled(distanceFromBottom: far, panelHeight: panel)
        #expect(!mac.showsCollapsedBrief, "The Mac panel never collapses its brief")

        #expect(TimelineFollow.collapsedSummary(title: "Ship it", next: "Run tests", question: nil)
            == .init(title: "Ship it", detail: "Next: Run tests", isQuestion: false))
        #expect(TimelineFollow.collapsedSummary(title: "Ship it", next: "Run tests", question: "Merge now?")
            == .init(title: "Ship it", detail: "Merge now?", isQuestion: true))
        #expect(TimelineFollow.collapsedSummary(title: "Ship it", next: nil, question: nil)
            == .init(title: "Ship it", detail: nil, isQuestion: false))
    }

    /// Collapsing the brief grows the timeline from the top, which shrinks the distance
    /// from the bottom by the brief's height change; expanding grows it back. The brief
    /// is capped at half the panel, so that change is always under half the panel.
    @Test(arguments: [0.0, 100.0, 300.0])
    func mobileBriefResizeDoesNotToggleItBack(barHeight: Double) {
        let panelHeight = 800.0, briefDelta = panelHeight / 2 - barHeight - 1
        var mobile = TimelineFollow(collapsesBrief: true)
        var distance = 0.0
        /// Scrolls to `target`, then replays the resize feedback; returns how often the brief toggled.
        func scroll(to target: Double) -> Int {
            distance = target
            var toggles = 0
            for _ in 0..<6 {
                let collapsed = mobile.showsCollapsedBrief
                mobile.scrolled(distanceFromBottom: distance, panelHeight: panelHeight)
                guard mobile.showsCollapsedBrief != collapsed else { break }
                toggles += 1
                distance += mobile.showsCollapsedBrief ? -briefDelta : briefDelta
            }
            return toggles
        }

        #expect(scroll(to: 100) == 0)
        #expect(!mobile.showsCollapsedBrief, "Scrolled less than half the panel away, the brief stays expanded")
        #expect(scroll(to: panelHeight / 2 + 25) == 1)
        #expect(mobile.showsCollapsedBrief, "Collapsing must not bring the reader back to the bottom")
        #expect(scroll(to: 25) == 0)
        #expect(mobile.showsCollapsedBrief, "Short of the bottom, the collapsed brief stays collapsed")
        #expect(scroll(to: 24) == 1)
        #expect(!mobile.showsCollapsedBrief, "Restoring must not push the reader far enough to collapse again")
    }
}
