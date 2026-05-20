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

        // Pure black (isDark=true) + 6% shift → 0.06 across all channels.
        let veryDark = GhosttyThemeColors(
            backgroundRGB: .init(r: 0.0, g: 0.0, b: 0.0),
            foregroundRGB: .init(r: 1.0, g: 1.0, b: 1.0))
        let veryDarkSide = veryDark.sidebarBackgroundRGB
        #expect(abs(veryDarkSide.r - 0.06) < 0.001)
        #expect(abs(veryDarkSide.g - 0.06) < 0.001)
        #expect(abs(veryDarkSide.b - 0.06) < 0.001)

        // Pure white (isDark=false) − 6% shift → 0.94 across all channels.
        let veryLight = GhosttyThemeColors(
            backgroundRGB: .init(r: 1.0, g: 1.0, b: 1.0),
            foregroundRGB: .init(r: 0.0, g: 0.0, b: 0.0))
        let veryLightSide = veryLight.sidebarBackgroundRGB
        #expect(abs(veryLightSide.r - 0.94) < 0.001)
        #expect(abs(veryLightSide.g - 0.94) < 0.001)
        #expect(abs(veryLightSide.b - 0.94) < 0.001)
    }

    @Test("Color builders return SwiftUI Color in sRGB")
    func colorBuildersExist() {
        let theme = GhosttyThemeColors.fallback
        _ = theme.background
        _ = theme.foreground
        _ = theme.sidebarBackground
    }

    // MARK: - Sidebar text-color opacity ladders (shared with Mac sidebar)

    @Test("sidebarPrimaryOpacity: 1.0 when active, 0.8 when inactive")
    func sidebarPrimaryOpacityLadder() {
        #expect(GhosttyThemeColors.sidebarPrimaryOpacity(isActive: true) == 1.0)
        #expect(GhosttyThemeColors.sidebarPrimaryOpacity(isActive: false) == 0.8)
    }

    @Test("sidebar dim/secondary/stale constants match Mac SidebarView values")
    func sidebarDimConstants() {
        #expect(GhosttyThemeColors.sidebarStaleOpacity == 0.5)
        #expect(GhosttyThemeColors.sidebarSecondaryOpacity == 0.45)
        #expect(GhosttyThemeColors.sidebarDimIconOpacity == 0.6)
        #expect(GhosttyThemeColors.sidebarChevronOpacity == 0.55)
    }

    @Test("paneArrowOpacity ladder: focused=0.75, active-worktree=0.5, inactive=0.35")
    func paneArrowOpacityLadder() {
        // Focused beats everything.
        #expect(GhosttyThemeColors.paneArrowOpacity(isFocusedPane: true, isActiveWorktree: true) == 0.75)
        #expect(GhosttyThemeColors.paneArrowOpacity(isFocusedPane: true, isActiveWorktree: false) == 0.75)
        // Non-focused inside the active worktree.
        #expect(GhosttyThemeColors.paneArrowOpacity(isFocusedPane: false, isActiveWorktree: true) == 0.5)
        // Non-focused outside the active worktree (baseline dim).
        #expect(GhosttyThemeColors.paneArrowOpacity(isFocusedPane: false, isActiveWorktree: false) == 0.35)
    }

    @Test("paneTitleOpacity ladder: focused=1.0, active+title=0.75, active+empty=0.55, inactive+title=0.55, inactive+empty=0.35")
    func paneTitleOpacityLadder() {
        // Focused — title content doesn't matter, always full brightness.
        #expect(GhosttyThemeColors.paneTitleOpacity(isFocusedPane: true, isActiveWorktree: true, hasTitle: true) == 1.0)
        #expect(GhosttyThemeColors.paneTitleOpacity(isFocusedPane: true, isActiveWorktree: true, hasTitle: false) == 1.0)
        // Non-focused inside the active worktree: real title brighter than empty.
        #expect(GhosttyThemeColors.paneTitleOpacity(isFocusedPane: false, isActiveWorktree: true, hasTitle: true) == 0.75)
        #expect(GhosttyThemeColors.paneTitleOpacity(isFocusedPane: false, isActiveWorktree: true, hasTitle: false) == 0.55)
        // Inactive worktree: dimmer overall.
        #expect(GhosttyThemeColors.paneTitleOpacity(isFocusedPane: false, isActiveWorktree: false, hasTitle: true) == 0.55)
        #expect(GhosttyThemeColors.paneTitleOpacity(isFocusedPane: false, isActiveWorktree: false, hasTitle: false) == 0.35)
    }

    @Test("Color accessors return SwiftUI Colors derived from foreground at the matching opacity")
    func colorAccessorsExist() {
        let theme = GhosttyThemeColors.fallback
        // Just exercise the accessors so the test fails-to-build if a
        // signature changes or one is removed. The opacity math is
        // covered by the ladder tests above.
        _ = theme.sidebarPrimaryText(isActive: true)
        _ = theme.sidebarPrimaryText(isActive: false)
        _ = theme.sidebarStaleText
        _ = theme.sidebarSecondaryText
        _ = theme.sidebarDimIcon
        _ = theme.sidebarChevron
        _ = theme.paneArrow(isFocusedPane: false, isActiveWorktree: false)
        _ = theme.paneTitle(isFocusedPane: false, isActiveWorktree: false, hasTitle: true)
    }
}
