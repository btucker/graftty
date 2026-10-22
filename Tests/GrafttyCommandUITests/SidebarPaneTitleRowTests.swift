import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
@Suite("SidebarPaneTitleRow")
struct SidebarPaneTitleRowTests {
    /// Mobile uses the default initializer; the Mac passes `.firstTextBaseline`.
    @Test("Shared pane row defaults to centre alignment and passes the title through unchanged")
    func defaultsMatchMobile() {
        let row = SidebarPaneTitleRow(title: "", isFocusedPane: false, isActiveWorktree: false, isBusy: false,
                                      attentionStyle: nil, attentionCount: 0, theme: nil)
        #expect(row.alignment == .center)
        #expect(row.titleLayout.title == row.title.title)
    }
}
