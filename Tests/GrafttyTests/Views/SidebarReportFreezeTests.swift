import Foundation
import Testing
@testable import Graftty

struct SidebarReportFreezeTests {
    @Test("@spec LAYOUT-2.246: While a Mac report popover is open, the application shall keep sidebar rows in the positions they had when the first report opened, including when the user moves to another report and when the Mac has no local repository, and shall release them when the last report closes.")
    func holdsFirstCaptureUntilLastReportCloses() {
        var freeze = SidebarReportFreeze()
        var captures = 0
        let repo = UUID()
        func capture(_ order: [UUID: [UUID]]) -> () -> SidebarReportFreeze.Snapshot {
            { captures += 1; return .init(worktreeOrder: order) }
        }

        // A Mac with only remote hosts captures nothing locally; that is still a freeze.
        freeze.reportChanged(isOpen: true, capture: capture([:]))
        freeze.reportChanged(isOpen: true, capture: capture([repo: [UUID()]]))
        #expect(captures == 1)
        #expect(freeze.snapshot?.worktreeOrder.isEmpty == true)

        freeze.reportChanged(isOpen: false, capture: capture([:]))
        #expect(freeze.snapshot == nil)
        #expect(captures == 1)

        let held = [repo: [UUID(), UUID()]]
        freeze.reportChanged(isOpen: true, capture: capture(held))
        freeze.reportChanged(isOpen: true, capture: capture([:]))
        #expect(captures == 2)
        #expect(freeze.snapshot?.worktreeOrder == held)
    }
}
