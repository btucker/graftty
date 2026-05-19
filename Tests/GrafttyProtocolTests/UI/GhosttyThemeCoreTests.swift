import Testing
import SwiftUI
@testable import GrafttyProtocol

@Suite("GhosttyThemeColors — cross-platform theme math")
struct GhosttyThemeCoreTests {

    @Test("fallback is dark with the expected RGB defaults")
    func fallbackDefaults() {
        let theme = GhosttyThemeColors.fallback
        #expect(theme.backgroundRGB.r == 0.05)
        #expect(theme.backgroundRGB.g == 0.05)
        #expect(theme.backgroundRGB.b == 0.10)
        #expect(theme.foregroundRGB.r == 0.87)
        #expect(theme.isDark == true)
    }

    @Test("isDark uses luminance threshold of 0.5")
    func isDarkLuminanceThreshold() {
        let nearBlack = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.1, g: 0.1, b: 0.1),
            foregroundRGB: .init(r: 0.9, g: 0.9, b: 0.9))
        #expect(nearBlack.isDark == true)

        let nearWhite = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.95, g: 0.95, b: 0.95),
            foregroundRGB: .init(r: 0.1, g: 0.1, b: 0.1))
        #expect(nearWhite.isDark == false)

        // Pure mid-gray: luminance = 0.299*0.5 + 0.587*0.5 + 0.114*0.5 = 0.5 → not dark.
        let midGray = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.5, g: 0.5, b: 0.5),
            foregroundRGB: .init(r: 0.5, g: 0.5, b: 0.5))
        #expect(midGray.isDark == false)
    }

    @Test("sidebarBackground shifts +6% on dark, -6% on light, clamps to [0,1]")
    func sidebarBackgroundShift() {
        let dark = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.10, g: 0.10, b: 0.10),
            foregroundRGB: .init(r: 0.9, g: 0.9, b: 0.9))
        let darkSide = dark.sidebarBackgroundRGB
        #expect(abs(darkSide.r - 0.16) < 0.001)
        #expect(abs(darkSide.g - 0.16) < 0.001)
        #expect(abs(darkSide.b - 0.16) < 0.001)

        let light = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.95, g: 0.95, b: 0.95),
            foregroundRGB: .init(r: 0.1, g: 0.1, b: 0.1))
        let lightSide = light.sidebarBackgroundRGB
        #expect(abs(lightSide.r - 0.89) < 0.001)
        #expect(abs(lightSide.g - 0.89) < 0.001)
        #expect(abs(lightSide.b - 0.89) < 0.001)

        // Clamp: nearly-black dark theme + 6% shift mustn't drift negative.
        let veryDark = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.0, g: 0.0, b: 0.0),
            foregroundRGB: .init(r: 1.0, g: 1.0, b: 1.0))
        let veryDarkSide = veryDark.sidebarBackgroundRGB
        #expect(veryDarkSide.r >= 0.0 && veryDarkSide.r <= 1.0)

        // Clamp: nearly-white light theme − 6% shift mustn't exceed 1.
        let veryLight = GhosttyThemeColors(
            backgroundRGB: .init(r: 1.0, g: 1.0, b: 1.0),
            foregroundRGB: .init(r: 0.0, g: 0.0, b: 0.0))
        let veryLightSide = veryLight.sidebarBackgroundRGB
        #expect(veryLightSide.r >= 0.0 && veryLightSide.r <= 1.0)
    }

    @Test("Color builders return SwiftUI Color in sRGB")
    func colorBuildersExist() {
        let theme = GhosttyThemeColors.fallback
        _ = theme.background
        _ = theme.foreground
        _ = theme.sidebarBackground
    }
}
