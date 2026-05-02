#if canImport(UIKit)
import GhosttyTerminal
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
@spec IOS-6.7: While a terminal pane is rendered in the iOS app, GrafttyMobile shall prevent libghostty-spm's built-in `TerminalInputAccessoryView` from appearing by routing terminal hit-testing through the app-owned `UIKeyInput` proxy and suppressing `UITerminalView.inputAccessoryView` at the UIKit ObjC dispatch path. The only visible software-keyboard accessory row shall be GrafttyMobile's terminal control bar (`IOS-6.1`).
""")
    func terminalPaneShowsOnlyGrafttyKeyboardAccessory() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.layoutIfNeeded()

        let hitView = container.hitTest(CGPoint(x: 160, y: 120), with: nil)

        #expect(hitView === container.inputProxy)
        #expect(hitView !== container.terminalView)

        UITerminalView.suppressGhosttyInputAccessory()
        // UIKit reads the first responder's `inputAccessoryView` through
        // `objc_msgSend`, so the assertion mirrors that path. Direct
        // Swift property access on a concrete type can statically
        // dispatch and bypass the runtime IMP swap, hiding the
        // suppression in production.
        let accessory = UITerminalView(frame: .zero).perform(
            #selector(getter: UIResponder.inputAccessoryView)
        )?.takeUnretainedValue()
        #expect(accessory == nil)
    }
}
#endif
