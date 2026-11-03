import Foundation
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit
#if canImport(UIKit)
import UIKit
#endif

@Suite
@MainActor
struct TerminalControllerThemeTests {
    #if canImport(UIKit)
    /// Measurement probe: how far can output outrun a real parser, and what
    /// does the backlog cost an echo queued behind it? Numeric report only.
    @Test("Parser backlog probe",
          .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TERMINAL_FLOW_PROBES"] != nil),
          .timeLimit(.minutes(3)))
    func parserBacklogProbe() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let view = UITerminalView(frame: window.bounds)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        view.configuration = .init(backend: .inMemory(session))
        view.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        host.view.addSubview(view)
        defer { view.removeFromSuperview(); window.isHidden = true }
        _ = try #require(view.surface)
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        let payloads: [(String, String)] = [
            ("styledLog", "\u{1b}[32mok\u{1b}[0m compiled module \u{1b}[1mexample\u{1b}[0m in 12ms with several warnings\r\n"),
            // Every cell addressed and truecolor styled, like a TUI full redraw.
            ("truecolorRedraw", (1...40).map { row in (1...40).map { "\u{1b}[\(row);\($0)H\u{1b}[38;2;\($0);\(row);9m\u{1b}[48;2;1;\(row);\($0)mx" }.joined() }.joined()),
            ("wideGraphemes", String(repeating: "👩‍💻漢字é ", count: 40) + "\r\n"),
            ("titleUpdates", (0..<20).map { "\u{1b}]0;title \($0)\u{07}line\r\n" }.joined())
        ]
        for (name, text) in payloads {
            var chunk = Data()
            let unit = Data(text.utf8)
            while chunk.count < 256 * 1024 { chunk.append(unit) }
            // Title updates parse far more slowly; keep the ordinary run short.
            let total = (name == "titleUpdates" ? 4 : 32) * 1024 * 1024
            var fed = 0
            var peak = 0
            let start = ContinuousClock.now
            while fed < total {
                session.receive(chunk)
                fed += chunk.count
                peak = max(peak, session.pendingOutputByteCount)
                await Task.yield()
            }
            let feed = milliseconds(start.duration(to: .now))
            // Yield the main thread, as a live terminal does. Blocking in
            // waitForPendingOutput ticks the mailbox only every 10 ms, which
            // would measure that wait rather than the parser.
            while session.pendingOutputByteCount > 0 { try await Task.sleep(for: .milliseconds(1)) }
            let drained = session.waitForPendingOutput()
            let parsed = milliseconds(start.duration(to: .now))
            // The same input, while something else holds the main thread for
            // most of each frame, as heavy layout or rendering would.
            let busyStart = ContinuousClock.now
            var busyFed = 0
            var busyPeak = 0
            while busyFed < 4 * 1024 * 1024 {
                session.receive(chunk)
                busyFed += chunk.count
                busyPeak = max(busyPeak, session.pendingOutputByteCount)
                let held = ContinuousClock.now
                while held.duration(to: .now) < .milliseconds(12) {}
                try await Task.sleep(for: .milliseconds(4))
            }
            while session.pendingOutputByteCount > 0 {
                let held = ContinuousClock.now
                while held.duration(to: .now) < .milliseconds(12) {}
                busyPeak = max(busyPeak, session.pendingOutputByteCount)
                try await Task.sleep(for: .milliseconds(4))
            }
            let busy = milliseconds(busyStart.duration(to: .now))
            print("[terminal-flow] {\"scenario\":\"parserBacklog\",\"payload\":\"\(name)\",\"fedBytes\":\(fed),\"peakPendingBytes\":\(peak),\"feedMilliseconds\":\(feed),\"parsedAllMilliseconds\":\(parsed),\"megabytesPerSecond\":\(Double(fed) / 1_048_576 / (parsed / 1000)),\"busyMainPeakPendingBytes\":\(busyPeak),\"busyMainMegabytesPerSecond\":\(Double(busyFed) / 1_048_576 / (busy / 1000)),\"drained\":\(drained)}")
        }
    }
    #endif

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
