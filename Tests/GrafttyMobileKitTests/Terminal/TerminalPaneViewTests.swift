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
}
#endif
