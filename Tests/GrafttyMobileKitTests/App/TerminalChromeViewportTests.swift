import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite("""
@spec IOS-6.11: While mobile terminal chrome is overlaid at the bottom of a
fullscreen session, the terminal viewport used for rendering and font-fit
decisions shall reserve that measured chrome height. The visual overlay
placement remains bottom-aligned; only the terminal content size is reduced.
""")
struct TerminalChromeViewportTests {

    @Test
    func fullSoftwareKeyboardControlBarReducesTerminalHeight() {
        let container = CGSize(width: 390, height: 502)

        let terminal = TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: 58
        )

        #expect(terminal.width == 390)
        #expect(terminal.height == 444)
    }

    @Test
    func compactShowKeyboardAffordanceReducesTerminalHeight() {
        let container = CGSize(width: 390, height: 502)

        let terminal = TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: 52
        )

        #expect(terminal.width == 390)
        #expect(terminal.height == 450)
    }

    @Test
    func zeroOrUnknownChromeUsesFullContainerHeight() {
        let container = CGSize(width: 390, height: 502)

        #expect(TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: 0
        ) == container)
        #expect(TerminalChromeViewport.terminalSize(
            container: container,
            chromeHeight: nil
        ) == container)
    }

    @Test
    func terminalHeightClampsToAtLeastOnePoint() {
        let terminal = TerminalChromeViewport.terminalSize(
            container: CGSize(width: 390, height: 40),
            chromeHeight: 58
        )

        #expect(terminal.width == 390)
        #expect(terminal.height == 1)
    }

    @Test
    func fontFitTaskKeyIncludesReducedTerminalHeight() {
        let withFullBar = TerminalFontFitTaskKey(
            containerSize: CGSize(width: 390, height: 444),
            authoritativeCols: 120,
            isOwner: false,
            baseConfig: "font-size = 11"
        )
        let withCompactAffordance = TerminalFontFitTaskKey(
            containerSize: CGSize(width: 390, height: 450),
            authoritativeCols: 120,
            isOwner: false,
            baseConfig: "font-size = 11"
        )

        #expect(withFullBar != withCompactAffordance)
    }
}
