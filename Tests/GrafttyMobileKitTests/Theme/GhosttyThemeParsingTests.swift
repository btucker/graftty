#if canImport(UIKit)
import Testing
@testable import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("GhosttyThemeColors.init(parsingConfigText:) — mobile-side hex parser")
struct GhosttyThemeParsingTests {

    @Test("parses background and foreground hex with #")
    func parsesHexWithHash() {
        let text = """
        background = #1e1e2e
        foreground = #f8f8f2
        """
        let theme = GhosttyThemeColors(parsingConfigText: text)
        #expect(abs(theme.backgroundRGB.r - 0x1e/255.0) < 0.001)
        #expect(abs(theme.backgroundRGB.g - 0x1e/255.0) < 0.001)
        #expect(abs(theme.backgroundRGB.b - 0x2e/255.0) < 0.001)
        #expect(abs(theme.foregroundRGB.r - 0xf8/255.0) < 0.001)
    }

    @Test("parses hex without # prefix")
    func parsesHexWithoutHash() {
        let theme = GhosttyThemeColors(parsingConfigText: "background = 1e1e2e\nforeground = ffffff")
        #expect(abs(theme.backgroundRGB.r - 0x1e/255.0) < 0.001)
        #expect(theme.foregroundRGB.r == 1.0)
    }

    @Test("accepts uppercase hex")
    func parsesUppercase() {
        let theme = GhosttyThemeColors(parsingConfigText: "background = #1E1E2E\nforeground = #FFFFFF")
        #expect(abs(theme.backgroundRGB.r - 0x1e/255.0) < 0.001)
    }

    @Test("partial config: only background present — foreground falls back")
    func partialBackgroundOnly() {
        let theme = GhosttyThemeColors(parsingConfigText: "background = #ffffff")
        #expect(theme.backgroundRGB.r == 1.0)
        #expect(theme.foregroundRGB == GhosttyThemeColors.fallback.foregroundRGB)
    }

    @Test("commented lines are ignored")
    func commentedLinesIgnored() {
        let text = """
        # background = #000000
        background = #1e1e2e
        """
        let theme = GhosttyThemeColors(parsingConfigText: text)
        #expect(abs(theme.backgroundRGB.r - 0x1e/255.0) < 0.001)
    }

    @Test("named colors fall back (mobile doesn't parse names)")
    func namedColorFallsBack() {
        let theme = GhosttyThemeColors(parsingConfigText: "background = cyan\nforeground = white")
        #expect(theme.backgroundRGB == GhosttyThemeColors.fallback.backgroundRGB)
        #expect(theme.foregroundRGB == GhosttyThemeColors.fallback.foregroundRGB)
    }

    @Test("theme references fall back")
    func themeReferenceFallsBack() {
        let theme = GhosttyThemeColors(parsingConfigText: "theme = Dracula")
        #expect(theme.backgroundRGB == GhosttyThemeColors.fallback.backgroundRGB)
    }

    @Test("garbage text falls back cleanly")
    func garbageFallsBack() {
        let theme = GhosttyThemeColors(parsingConfigText: "this is not a config")
        #expect(theme.backgroundRGB == GhosttyThemeColors.fallback.backgroundRGB)
        #expect(theme.foregroundRGB == GhosttyThemeColors.fallback.foregroundRGB)
    }

    @Test("last value wins (ghostty's later-overrides-earlier rule)")
    func lastValueWins() {
        let text = """
        background = #000000
        background = #ffffff
        """
        let theme = GhosttyThemeColors(parsingConfigText: text)
        #expect(theme.backgroundRGB.r == 1.0)
    }
}
#endif
