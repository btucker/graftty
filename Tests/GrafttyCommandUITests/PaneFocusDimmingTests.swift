import Testing
@testable import GrafttyCommandUI

@Suite("Shared pane-focus dimming")
struct PaneFocusDimmingTests {
    @Test("focused panes have no overlay")
    func focusedPaneIsClear() {
        let style = PaneFocusDimmingStyle(
            isUnfocused: false,
            contentOpacity: 0.7
        )

        #expect(!style.isVisible)
        #expect(style.overlayOpacity == 0)
    }

    @Test("Ghostty content opacity is converted to inverse fill opacity")
    func contentOpacityBecomesInverseOverlayOpacity() {
        let style = PaneFocusDimmingStyle(
            isUnfocused: true,
            contentOpacity: 0.7
        )

        #expect(style.isVisible)
        #expect(abs(style.overlayOpacity - 0.3) < 0.0001)
    }

    @Test("out-of-range opacity is safely clamped")
    func clampsOpacity() {
        #expect(PaneFocusDimmingStyle(
            isUnfocused: true,
            contentOpacity: -1
        ).overlayOpacity == 1)
        #expect(PaneFocusDimmingStyle(
            isUnfocused: true,
            contentOpacity: 2
        ).overlayOpacity == 0)
    }
}
