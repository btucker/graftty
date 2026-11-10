#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import CoreGraphics
        import Foundation
        import UIKit
        import Testing
        @testable import GhosttyTerminal

        @MainActor
        struct UIKitHostViewportFlowTests {
            @Test
            func hostRequestPairsLogicalTextWithItsNativeWordAnchor() async throws {
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
                let host = UIViewController()
                let view = UITerminalView(frame: window.bounds)
                let replies = ViewportFlowReplies()
                let session = InMemoryTerminalSession(write: { replies.append($0) }, resize: { _ in })
                let controller = TerminalController()
                let delegate = ViewportFlowDelegate()
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.addSubview(view)
                view.configuration = .init(backend: .inMemory(session))
                view.controller = controller
                view.delegate = delegate
                defer {
                    view.removeFromSuperview()
                    window.isHidden = true
                }

                let surface = try #require(view.surface)
                let size = try #require(surface.size())
                // UI grid metrics lead the parser's asynchronous resize. A
                // clamped cursor report proves the native grid reached them.
                let bottomRight = "\u{1b}[\(size.rows);\(size.columns)R"
                for _ in 0..<100 where !replies.contains(bottomRight) {
                    session.receive("\u{1b}[999;999H\u{1b}[6n")
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(replies.contains(bottomRight))
                let prefix = String(repeating: "a", count: Int(size.columns) + 5)
                let expectedText = prefix + "\n\n你好 cat cat"
                session.receive("\u{1b}[H\u{1b}[2J" + prefix + "\r\n\r\n你好 cat cat")
                for _ in 0..<100 where session.readViewportText()?.hasPrefix(expectedText) != true {
                    controller.tick()
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(session.readViewportText()?.hasPrefix(expectedText) == true)
                view.core.requestImmediateTick()
                view.core.tick()
                let scale = Double(view.contentScaleFactor)
                let point = CGPoint(
                    x: 9.5 * Double(size.cellWidthPixels) / scale,
                    y: 3.5 * Double(size.cellHeightPixels) / scale
                )
                surface.sendMousePos(x: point.x, y: point.y)
                view.requestHostTextSelection(at: point)

                let request = try #require(delegate.request)
                #expect(request.text.hasPrefix(prefix + "\n\n你好 cat cat"))
                #expect(request.sourcePoint == point)
                #expect(request.anchorRange == NSRange(location: prefix.utf16.count + 2 + 7, length: 3))
            }
        }

        @MainActor
        private final class ViewportFlowDelegate: TerminalSurfaceTextSelectionRequestDelegate {
            var request: TerminalTextSelectionRequest?
            func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
                self.request = request
            }
        }

        private final class ViewportFlowReplies: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func append(_ bytes: Data) {
                lock.lock()
                defer { lock.unlock() }
                data.append(bytes)
            }

            func contains(_ text: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return data.range(of: Data(text.utf8)) != nil
            }
        }
    #endif
#endif
