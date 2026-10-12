import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit
#if canImport(UIKit)
import UIKit
#endif

@Suite
@MainActor
struct TerminalControllerThemeTests {
    #if canImport(UIKit) && GRAFTTY_PAGED_HISTORY
    @Test("Native iOS terminal preserves ANSI indexed and truecolor styles in history")
    func nativeANSIColors() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let view = UITerminalView(frame: window.bounds)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = MobileTerminalControllerFactory.make(configText: """
        font-size = 14
        palette = 1=#cc241d
        palette = 2=#98971a
        """)
        view.configuration = .init(backend: .inMemory(session))
        view.controller = controller
        host.view.addSubview(view)
        defer { view.removeFromSuperview(); window.isHidden = true }
        let surface = try #require(view.surface)
        session.receive("\u{1b}[31mRED\u{1b}[0m \u{1b}[32mGREEN\u{1b}[0m \u{1b}[38;2;1;2;3mRGB\u{1b}[0m\r\n"
            + (0..<40).map { "filler \($0)" }.joined(separator: "\r\n"))
        for _ in 0..<100 where session.readViewportText()?.contains("filler 39") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.readViewportText()?.contains("filler 39") == true)
        let history = try #require(surface.readHistory(beforeRow: 1, rows: 1))
        let text = String(decoding: history.bytes, as: UTF8.self)
        #expect(text.contains("RED"))
        #expect(text.contains("GREEN"))
        #expect(text.contains("\u{1b}[38;2;204;36;29m"))
        #expect(text.contains("\u{1b}[38;2;152;151;26m"))
        #expect(text.contains("\u{1b}[38;2;1;2;3m"))
    }
    #endif

    @Test("""
@spec IOS-4.13: When GrafttyMobile constructs a `TerminalController` from the Mac-provided Ghostty config (`IOS-4.7`), it shall not install libghostty-spm's built-in light/dark `TerminalTheme` overlay. UIKit trait changes may still report the phone's `.light` or `.dark` color scheme to libghostty, but the rendered config shall continue to use the Mac config's background, foreground, palette, and theme-derived colors rather than switching to GhosttyTerminal's default Alabaster/Afterglow themes.
""")
    func mobileControllerPreservesGeneratedMacConfigAcrossPhoneColorSchemeChanges() {
        let macConfig = """
        background = #101010
        foreground = #f0f0f0
        palette = 1=#cc241d
        font-size = 12
        """
        let controller = MobileTerminalControllerFactory.make(configText: macConfig)
        #expect(controller.lastConfigurationIssue == nil)

        controller.setColorScheme(.light)
        #expect(controller.renderedConfig.contains("background = #101010"))
        #expect(controller.renderedConfig.contains("foreground = #f0f0f0"))
        #expect(controller.renderedConfig.contains("palette = 1=#cc241d"))

        controller.setColorScheme(.dark)
        #expect(controller.renderedConfig.contains("background = #101010"))
        #expect(controller.renderedConfig.contains("foreground = #f0f0f0"))
        #expect(controller.renderedConfig.contains("palette = 1=#cc241d"))
    }
}
