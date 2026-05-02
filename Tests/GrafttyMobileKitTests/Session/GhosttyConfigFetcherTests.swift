#if canImport(UIKit)
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite("""
@spec IOS-4.12: When the fetched Ghostty config specifies a single theme (not a light:X,dark:Y pair), \
the application shall force overrideUserInterfaceStyle on the terminal container view to match \
that theme's appearance so that libghostty-spm's traitCollectionDidChange → setColorScheme path \
never substitutes the system-default appearance over the user's explicit choice.
""")
struct GhosttyConfigFetcherInterfaceStyleTests {

    @Test func darkThemeYieldsDark() {
        let config = "theme = Gruvbox Dark Hard\nfont-size = 14\n"
        #expect(GhosttyConfigFetcher.preferredInterfaceStyle(for: config) == .dark)
    }

    @Test func quotedDarkThemeYieldsDark() {
        let config = "font-family = MonoLisa Variable\ntheme = \"Gruvbox Dark Hard\"\nfont-size = 14\n"
        #expect(GhosttyConfigFetcher.preferredInterfaceStyle(for: config) == .dark)
    }

    @Test func lightThemeNameYieldsLight() {
        let config = "theme = Solarized Light\n"
        #expect(GhosttyConfigFetcher.preferredInterfaceStyle(for: config) == .light)
    }

    @Test func adaptivePairYieldsUnspecified() {
        let config = "theme = light:GitHub Light,dark:Gruvbox Dark Hard\n"
        #expect(GhosttyConfigFetcher.preferredInterfaceStyle(for: config) == .unspecified)
    }

    @Test func noThemeYieldsUnspecified() {
        let config = "font-size = 14\nfont-family = MonoLisa\n"
        #expect(GhosttyConfigFetcher.preferredInterfaceStyle(for: config) == .unspecified)
    }

    @Test func lastThemeWins() {
        let config = "theme = Solarized Light\ntheme = Dracula\n"
        #expect(GhosttyConfigFetcher.preferredInterfaceStyle(for: config) == .dark)
    }

    @Test func commentLinesIgnored() {
        let config = "# theme = Solarized Light\ntheme = Dracula\n"
        #expect(GhosttyConfigFetcher.preferredInterfaceStyle(for: config) == .dark)
    }
}

@Suite("GhosttyConfigFetcher — scaledForIOS / lastFontSize")
struct GhosttyConfigFetcherFontTests {

    @Test func scaledForIOSAppendsFontSize() {
        let result = GhosttyConfigFetcher.scaledForIOS("font-size = 14\n")
        #expect(result.contains("font-size = 11.2"))
    }

    @Test func lastFontSizeNilWhenAbsent() {
        #expect(GhosttyConfigFetcher.lastFontSize(in: "theme = Dracula\n") == nil)
    }
}
#endif
