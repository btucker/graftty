import Testing
import Foundation
@testable import GrafttyKit

// The Settings pane's Port TextField uses `IntegerFormatStyle<Int>` to
// format the bound port into a text field. Plain `.number` is locale-
// aware and emits a grouping separator — port 12345 renders as "12,345"
// in en_US, which is (a) visually nonsense for a port and (b) round-
// trips through `Int`'s parser as 12345 but looks broken to the user.
// `WebPortFormat.noGrouping` is the shared formatter every UI surface
// that prints a port into a `TextField` or label uses.
@Suite("WebPortFormat — no locale grouping (WEB-1.7)")
struct WebPortFormatTests {

    @Test func formatsPortWithoutCommaForFiveDigitValue() {
        #expect(WebPortFormat.noGrouping.format(12345) == "12345")
    }

    @Test func formatsDefaultPortCleanly() {
        #expect(WebPortFormat.noGrouping.format(8799) == "8799")
    }

    @Test func formatsMaxPortCleanly() {
        #expect(WebPortFormat.noGrouping.format(65535) == "65535")
    }

    @Test func formatsZeroCleanly() {
        // Ephemeral-bind sentinel — integration tests rely on port 0.
        #expect(WebPortFormat.noGrouping.format(0) == "0")
    }
}
