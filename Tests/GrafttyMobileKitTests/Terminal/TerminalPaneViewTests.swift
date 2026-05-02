#if canImport(UIKit)
import Testing
@testable import GrafttyMobileKit
import UIKit

@Suite
@MainActor
struct TerminalPaneViewTests {

    @Test
    func softwareKeyboardProxyDoesNotExposeGhosttyAccessoryView() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.inputProxy.inputAccessoryView == nil)
        #expect(container.inputProxy !== container.terminalView)
    }

    @Test("""
@spec IOS-6.7: While a terminal pane is rendered in the iOS app, touch hit-testing shall route through GrafttyMobile's app-owned `UIKeyInput` proxy rather than directly to libghostty-spm's `UITerminalView`, so UIKit never asks the Ghostty terminal view for its built-in `inputAccessoryView`. The only visible software-keyboard accessory row shall be GrafttyMobile's terminal control bar (`IOS-6.1`).
""")
    func containerRoutesTouchesToKeyboardProxyInsteadOfGhosttyTerminal() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.layoutIfNeeded()

        let hitView = container.hitTest(CGPoint(x: 160, y: 120), with: nil)

        #expect(hitView === container.inputProxy)
        #expect(hitView !== container.terminalView)
    }
}
#endif
