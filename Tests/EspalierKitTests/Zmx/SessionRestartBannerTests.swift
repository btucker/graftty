import Testing
import Foundation
@testable import EspalierKit

@Suite("SessionRestartBanner")
struct SessionRestartBannerTests {

    /// The banner is the bytes Espalier prepends to a rebuilt pane's
    /// initial_input so the user sees a visible marker that the
    /// underlying zmx session was replaced. We test the pure formatter
    /// here; placement into initial_input is exercised by integration
    /// tests of the rebuild path.

    @Test func bannerWrapsTimestampInDimAnsi() {
        let date = Self.dateAt(hour: 14, minute: 23)
        let banner = sessionRestartBanner(at: date)
        #expect(banner.contains("14:23"))
        // The banner embeds *literal* `\033[2m` / `\033[0m` so the outer
        // shell's printf interprets them as ESC at runtime — we are not
        // looking for the real ESC byte here.
        #expect(banner.contains("\\033[2m"))
        #expect(banner.contains("\\033[0m"))
    }

    @Test func bannerEndsWithExecutableNewline() {
        let banner = sessionRestartBanner(at: Self.dateAt(hour: 9, minute: 5))
        #expect(banner.last == "\n")
    }

    @Test func bannerInvokesPrintfNotEcho() {
        let banner = sessionRestartBanner(at: Self.dateAt(hour: 0, minute: 0))
        #expect(banner.hasPrefix("printf "))
    }

    @Test func bannerZeroPadsSingleDigitHourAndMinute() {
        let banner = sessionRestartBanner(at: Self.dateAt(hour: 9, minute: 5))
        #expect(banner.contains("09:05"))
    }

    private static func dateAt(hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 19
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)!
    }
}
