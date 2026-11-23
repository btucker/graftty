import AppKit
import SwiftUI
import Testing
import GrafttyCommandUI

@MainActor
@Suite("@spec LAYOUT-2.245: When agent tabs are wider than their row, the application shall shrink the widest tabs first to an equal width, no narrower than a minimum, truncating their titles in the middle, and scroll only the tabs that still do not fit.")
struct AgentTabStripLayoutTests {
    @Test func keepsIdealWidthsWhenTabsFit() {
        let widths = AgentTabStripLayout.tabWidths(ideal: [80, 120, 60], available: 400, fixed: 30, spacing: 2)
        #expect(widths == [80, 120, 60])
    }

    @Test func shrinksOnlyTheWidestTabsToAnEqualShare() {
        // Budget for tabs: 400 - 32 fixed (with its gap) - 2 gaps of 2 = 364. The short
        // tab keeps 64, and the long tabs share the remaining 300.
        let widths = AgentTabStripLayout.tabWidths(ideal: [64, 400, 250], available: 400, fixed: 32, spacing: 2)
        #expect(widths == [64, 150, 150])
    }

    @Test func stopsShrinkingAtTheMinimum() {
        let widths = AgentTabStripLayout.tabWidths(ideal: [300, 300, 40], available: 120, fixed: 0, spacing: 0,
                                                   minimum: 72)
        #expect(widths == [72, 72, 40])
    }

    @Test func rendersLongTitlesWithinTheRow() throws {
        let title = "a-very-long-agent-title-that-would-never-fit-in-a-narrow-tab-row"
        let strip = AgentTabStripLayout(available: 320, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Text("\(index) \(title)").lineLimit(1).truncationMode(.middle).padding(.horizontal, 12)
            }
            Text("+").agentTabStripFixed()
        }
        let renderer = ImageRenderer(content: strip)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 320)
    }
}
