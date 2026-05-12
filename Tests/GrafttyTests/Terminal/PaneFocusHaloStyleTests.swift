import Testing
@testable import Graftty

struct PaneFocusHaloStyleTests {
    @Test func hiddenWhenPaneIsNotFocused() {
        let style = GhosttyTheme.fallback.paneFocusHaloStyle(
            isFocused: false,
            isWindowKey: true
        )

        #expect(!style.isVisible)
    }

    @Test func activeWindowUsesStrongerForegroundHalo() {
        let active = GhosttyTheme.fallback.paneFocusHaloStyle(
            isFocused: true,
            isWindowKey: true
        )
        let inactive = GhosttyTheme.fallback.paneFocusHaloStyle(
            isFocused: true,
            isWindowKey: false
        )

        #expect(active.isVisible)
        #expect(inactive.isVisible)
        #expect(active.strokeOpacity > inactive.strokeOpacity)
        #expect(active.glowOpacity > inactive.glowOpacity)
        #expect(active.glowRadius > inactive.glowRadius)
    }
}
