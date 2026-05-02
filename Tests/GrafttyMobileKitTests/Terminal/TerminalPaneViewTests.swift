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
        let proxy = TerminalSoftwareKeyboardProxyView(frame: .zero)
        let terminal = UITerminalView(frame: .zero)
        proxy.terminalView = terminal

        #expect(proxy.inputAccessoryView == nil)
    }

    @Test("@spec IOS-6.7: While a terminal pane is focused on iOS, libghostty-spm's built-in `TerminalInputAccessoryView` shall be suppressed so the only chrome above the software keyboard is the graftty-owned terminal control bar (`IOS-6.1`).")
    func wrappedTerminalViewSuppressesGhosttyAccessoryViaObjC() {
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
