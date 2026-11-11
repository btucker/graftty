import Testing
@testable import GrafttyCommandUI

struct TimelineFollowTests {
    @Test("@spec CONTEXT-28: When a new event arrives in the Context timeline, the application shall scroll to it only while the reader is at the bottom of the timeline, and otherwise shall show a Jump to latest control that scrolls to the latest event and disappears when used or when the reader returns to the bottom.")
    func followsOnlyAtBottomOtherwiseOffersJump() {
        var follow = TimelineFollow()
        #expect(follow.isAtBottom)
        #expect(follow.receivedEvent() == true, "At the bottom, a new event scrolls into view")
        #expect(!follow.showsJumpToLatest)

        follow.scrolled(distanceFromBottom: 25)
        #expect(follow.receivedEvent() == false, "Scrolled away, a new event must not move the reader")
        #expect(follow.showsJumpToLatest)
        #expect(follow.receivedEvent() == false)
        #expect(follow.showsJumpToLatest)

        follow.jumpToLatest()
        #expect(!follow.showsJumpToLatest)
        #expect(follow.isAtBottom)
        #expect(follow.receivedEvent() == true)

        follow.scrolled(distanceFromBottom: 25)
        _ = follow.receivedEvent()
        follow.scrolled(distanceFromBottom: 24)
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
            visibleHeight: visible))
        #expect(follow.isAtBottom == expected)
    }
}
