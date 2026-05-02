import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit

@Suite
@MainActor
struct TerminalControllerThemeTests {
    @Test("""
@spec IOS-4.13: When GrafttyMobile constructs a `TerminalController` from the Mac-provided Ghostty config (`IOS-4.7`), it shall not install libghostty-spm's built-in light/dark `TerminalTheme` overlay. UIKit trait changes may still report the phone's `.light` or `.dark` color scheme to libghostty, but the rendered config shall continue to use the Mac config's background, foreground, palette, and theme-derived colors rather than switching to GhosttyTerminal's default Alabaster/Afterglow themes.
""")
    func mobileControllerPreservesGeneratedMacConfigAcrossPhoneColorSchemeChanges() {
        let macConfig = """
        background = #101010
        foreground = #f0f0f0
        font-size = 12
        """
        let controller = MobileTerminalControllerFactory.make(configText: macConfig)

        controller.setColorScheme(.light)
        #expect(controller.renderedConfig.contains("background = #101010"))
        #expect(controller.renderedConfig.contains("foreground = #f0f0f0"))

        controller.setColorScheme(.dark)
        #expect(controller.renderedConfig.contains("background = #101010"))
        #expect(controller.renderedConfig.contains("foreground = #f0f0f0"))
    }
}
