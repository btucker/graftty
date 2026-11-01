#if os(macOS)
import AppKit
import Testing
@testable import GrafttyCommandUI

@MainActor
struct HorizontalResizeDividerTests {
    @Test("@spec LAYOUT-2.185: When a user adjusts a native horizontal divider through accessibility, the application shall resize by twenty points and commit the adjustment.")
    func accessibilityResizeCommits() {
        let divider = HorizontalResizeDividerView()
        divider.configure(label: "Terminal drawer height", separatorIdentifier: nil)
        var changes: [CGFloat] = []
        var commits = 0
        divider.onResize = { changes.append($0) }
        divider.onResizeEnd = { commits += 1 }
        #expect(divider.accessibilityPerformIncrement())
        #expect(divider.accessibilityPerformDecrement())
        #expect(changes == [20, -20])
        #expect(commits == 2)
        #expect(divider.accessibilityRole() == .splitter)
    }
}
#endif
