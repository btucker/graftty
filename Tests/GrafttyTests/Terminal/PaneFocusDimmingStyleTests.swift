import Testing
@testable import Graftty

struct PaneFocusDimmingStyleTests {
    @Test func focusedPaneIsNotDimmed() {
        let style = GhosttyTheme.fallback.paneFocusDimmingStyle(isUnfocused: false)

        #expect(!style.isVisible)
        #expect(style.overlayOpacity == 0)
    }

    @Test func fallbackThemeUsesGhosttyDefaultUnfocusedSplitOpacity() {
        let style = GhosttyTheme.fallback.paneFocusDimmingStyle(isUnfocused: true)

        #expect(style.isVisible)
        #expect(abs(style.overlayOpacity - 0.3) < 0.0001)
    }

    @Test func opacityOneDisablesUnfocusedSplitDimming() {
        let theme = GhosttyTheme(
            backgroundRGB: .init(r: 0.1, g: 0.2, b: 0.3),
            foregroundRGB: .init(r: 0.9, g: 0.8, b: 0.7),
            unfocusedSplitOpacity: 1
        )
        let style = theme.paneFocusDimmingStyle(isUnfocused: true)

        #expect(!style.isVisible)
        #expect(style.overlayOpacity == 0)
    }

    @Test func themeCarriesUnfocusedSplitFillAndOpacity() {
        let theme = GhosttyTheme(
            backgroundRGB: .init(r: 0x10 / 255.0, g: 0x18 / 255.0, b: 0x20 / 255.0),
            foregroundRGB: .init(r: 0.9, g: 0.8, b: 0.7),
            unfocusedSplitFillRGB: .init(r: 0x12 / 255.0, g: 0x34 / 255.0, b: 0x56 / 255.0),
            unfocusedSplitOpacity: 0.85
        )
        let style = theme.paneFocusDimmingStyle(isUnfocused: true)

        #expect(abs(style.overlayOpacity - 0.15) < 0.0001)
        #expect(theme.unfocusedSplitFillRGB == GhosttyTheme.RGB(
            r: 0x12 / 255.0,
            g: 0x34 / 255.0,
            b: 0x56 / 255.0
        ))
    }
}
