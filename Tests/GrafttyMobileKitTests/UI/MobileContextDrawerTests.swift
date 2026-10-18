import Testing
@testable import GrafttyMobileKit

struct MobileContextDrawerTests {
    @Test("@spec CONTEXT-5: When the user drags inward from the right edge on mobile, the application shall open the worktree context drawer only for a deliberate horizontal drag and shall preserve ordinary vertical scrolling.")
    func opensOnlyForInwardHorizontalDrag() {
        #expect(MobileContextDrawerGesture.shouldOpen(startX: 390, width: 400, x: -65, y: 10))
        #expect(!MobileContextDrawerGesture.shouldOpen(startX: 390, width: 400, x: 65, y: 0))
        #expect(!MobileContextDrawerGesture.shouldOpen(startX: 390, width: 400, x: -12, y: 0))
        #expect(!MobileContextDrawerGesture.shouldOpen(startX: 390, width: 400, x: -60, y: 100))
        #expect(!MobileContextDrawerGesture.shouldOpen(startX: 200, width: 400, x: -65, y: 0))
    }
}
