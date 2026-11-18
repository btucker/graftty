#if canImport(UIKit)
import Foundation
import GhosttyTerminal
import Testing
import UIKit
@testable import GrafttyMobileKit

@MainActor
struct MobileTerminalPresentationTests {
    @Test("@spec IOS-6.48: While a mobile terminal's content is unchanged, the application shall stop presenting frames rather than redraw on every display refresh, and shall present new output when it arrives.")
    func idleTerminalStopsPresentingUntilOutput() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let terminal = UITerminalView(frame: window.bounds)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        terminal.controller = MobileTerminalControllerFactory.make(
            configText: "font-size = 14\ncursor-style-blink = false"
        )
        terminal.configuration = .init(backend: .inMemory(session))
        host.view.addSubview(terminal)
        terminal.layoutIfNeeded()
        defer { terminal.removeFromSuperview(); window.isHidden = true }
        let layer = try #require(terminal.layer.sublayers?.first {
            NSStringFromClass(type(of: $0)) == "IOSurfaceLayer"
        })

        session.receive("ready\r\n")
        #expect(await session.flushOutput())
        // Wait for the output's frame update and the draws it requests to
        // settle. A render request answered with another frame update would
        // replace the contents every display refresh and never settle.
        var settled = layer.contents as AnyObject?
        var unchangedSamples = 0
        for _ in 0..<200 where unchangedSamples < 20 {
            try await Task.sleep(for: .milliseconds(16))
            let current = layer.contents as AnyObject?
            unchangedSamples = current === settled ? unchangedSamples + 1 : 0
            settled = current
        }
        #expect(unchangedSamples == 20)
        let presentedOutput = try #require(settled)

        // The renderer thread does not present on iOS; its request for a
        // host draw must still bring new output to the screen.
        session.receive("more\r\n")
        #expect(await session.flushOutput())
        var presented = false
        for _ in 0..<100 where !presented {
            try await Task.sleep(for: .milliseconds(10))
            presented = layer.contents as AnyObject? !== presentedOutput
        }
        #expect(presented)
    }
}
#endif
