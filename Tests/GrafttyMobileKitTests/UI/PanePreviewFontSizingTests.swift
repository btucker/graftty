import Testing
@testable import GrafttyMobileKit

@Suite
struct PanePreviewFontSizingTests {
    @Test("""
@spec IOS-4.12: While the worktree-detail screen is rendering live pane previews (`IOS-4.10`), each `PaneTile` shall own its own `TerminalController` whose font-size is computed dynamically from the tile's geometry (`tileWidth / serverCols × monospaceAspect`) so the server's grid renders at scale 1 within the tile. The font is updated via `setTerminalConfiguration().fontSize(_)` whenever the tile width or the server's column count changes — including device rotation, since landscape gives each tile a different width. The preview shall not apply a runtime `scaleEffect` driven by libghostty's reported `cellWidthPoints`: that value is shared with the fullscreen view (`IOS-4.11`), which renders at a much larger font, so a feedback-loop safety-net would oscillate or progressively shrink the preview when the user navigates between the tile and fullscreen. Preview legibility is sacrificed for fit: previews communicate pane shape and live activity, not readable text. The fullscreen view (`IOS-4.11`) keeps the iOS-scaled font as it remains the primary read surface.
""")
    func fontSizeTracksTileWidthAndServerColumns() {
        let portrait = PanePreviewFontSizing.fontSize(tileWidth: 240, serverCols: 120)
        let landscape = PanePreviewFontSizing.fontSize(tileWidth: 480, serverCols: 120)
        let narrowerGrid = PanePreviewFontSizing.fontSize(tileWidth: 240, serverCols: 80)

        #expect(portrait == 3.1666667)
        #expect(landscape == 6.3333335)
        #expect(narrowerGrid == 4.75)
    }

    @Test
    func fontSizeFallsBackToEightyColumnsAndMinimumSize() {
        #expect(PanePreviewFontSizing.fontSize(tileWidth: 240, serverCols: nil) == 4.75)
        #expect(PanePreviewFontSizing.fontSize(tileWidth: 0, serverCols: 120) == 2)
        #expect(PanePreviewFontSizing.fontSize(tileWidth: 12, serverCols: 120) == 2)
    }
}
