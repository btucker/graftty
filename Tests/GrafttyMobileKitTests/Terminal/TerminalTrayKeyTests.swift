import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite("@spec IOS-6.29: While the terminal tray's Shift toggle is selected, the application shall send shifted arrow escape sequences and Shift-Tab as back-tab; while Shift is off, it shall send the unmodified arrow and Tab bytes.")
struct TerminalTrayKeyTests {
    @Test(arguments: [
        (TerminalTrayKey.up, "A"),
        (.down, "B"),
        (.left, "D"),
        (.right, "C"),
    ])
    func arrows(key: TerminalTrayKey, suffix: String) {
        #expect(key.data(shift: true) == Data("\u{1B}[1;2\(suffix)".utf8))
        #expect(key.data(shift: false) == Data("\u{1B}[\(suffix)".utf8))
    }

    @Test func tab() {
        #expect(TerminalTrayKey.tab.data(shift: true) == Data("\u{1B}[Z".utf8))
        #expect(TerminalTrayKey.tab.data(shift: false) == Data([0x09]))
    }
}
