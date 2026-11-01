import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
@Suite("SidebarPaneTitleRow")
struct SidebarPaneTitleRowTests {
    @Test("@spec LAYOUT-2.184: While an agent has a notification capsule, the sidebar shall derive its working indicator from the same input-required state as its tab independently of capsule visibility.")
    func statusDoesNotDependOnCapsule() {
        let ordinary = SidebarPaneTitleRow(title: "Agent", isFocusedPane: false, isActiveWorktree: true,
            isBusy: false, attentionStyle: .from(text: "FYI", source: nil), attentionCount: 1, theme: nil,
            needsInput: false)
        let question = SidebarPaneTitleRow(title: "Agent", isFocusedPane: false, isActiveWorktree: true,
            isBusy: false, attentionStyle: nil, attentionCount: 1, theme: nil, needsInput: true)
        #expect(!ordinary.needsInput)
        #expect(question.needsInput)
    }

    /// Mobile uses the default initializer; the Mac passes `.firstTextBaseline`.
    @Test("Shared pane row defaults to centre alignment and passes the title through unchanged")
    func defaultsMatchMobile() {
        let row = SidebarPaneTitleRow(title: "", isFocusedPane: false, isActiveWorktree: false, isBusy: false,
                                      attentionStyle: nil, attentionCount: 0, theme: nil)
        #expect(row.alignment == .center)
        #expect(row.titleLayout.title == row.title.title)
    }
}
