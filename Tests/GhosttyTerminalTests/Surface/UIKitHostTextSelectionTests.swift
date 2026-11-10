#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import CoreGraphics
        import Foundation
        import GhosttyKit
        import UIKit
        import Testing
        @testable import GhosttyTerminal

        @MainActor
        struct UIKitHostTextSelectionTests {
            @Test
            func hostSelectionDelegateOwnsTheExistingLongPress() throws {
                let view = UITerminalView(frame: .zero)
                let delegate = HostTextSelectionDelegate()
                let longPress = try #require(view.touchSelection.longPress)
                let originalLongPressCount = view.gestureRecognizers?
                    .filter { $0 is UILongPressGestureRecognizer }.count

                #expect(view.usesInlineTextSelection)
                #expect(view.touchSelection.tapRecognizers.allSatisfy { $0.isEnabled })
                view.delegate = delegate

                #expect(!view.usesInlineTextSelection)
                #expect(view.gestureRecognizerShouldBegin(longPress))
                #expect(view.touchSelection.tapRecognizers.allSatisfy { !$0.isEnabled })
                #expect(view.touchSelection.scrollGesture?.maximumNumberOfTouches == 1)
                #expect(view.gestureRecognizers?.filter { $0 === longPress }.count == 1)
                #expect(view.gestureRecognizers?.filter { $0 is UILongPressGestureRecognizer }.count == originalLongPressCount)

                view.delegate = nil

                #expect(view.usesInlineTextSelection)
                #expect(view.touchSelection.tapRecognizers.allSatisfy { $0.isEnabled })
                #expect(view.touchSelection.scrollGesture?.maximumNumberOfTouches == 2)
            }

            @Test
            func removingHostDelegatePreservesAnExplicitInlineOptOut() throws {
                let view = UITerminalView(frame: .zero)
                let delegate = HostTextSelectionDelegate()
                let longPress = try #require(view.touchSelection.longPress)
                view.usesInlineTextSelection = false
                view.delegate = delegate
                #expect(view.gestureRecognizerShouldBegin(longPress))

                view.delegate = nil

                #expect(!view.usesInlineTextSelection)
                #expect(!view.gestureRecognizerShouldBegin(longPress))
            }

            @Test
            func hostRequestContainsViewportTextAndTheOriginalPoint() throws {
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
                let controller = UIViewController()
                let view = UITerminalView(frame: window.bounds)
                let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
                let terminalController = TerminalController()
                let delegate = HostTextSelectionDelegate()
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.addSubview(view)
                view.configuration = .init(backend: .inMemory(session))
                view.controller = terminalController
                view.delegate = delegate
                _ = try #require(view.surface)
                session.receive("hello world")
                #expect(session.waitForPendingOutput())
                terminalController.tick()

                let point = CGPoint(x: 5, y: 5)
                view.requestHostTextSelection(at: point)

                let request = try #require(delegate.requests.first)
                #expect(delegate.requests.count == 1)
                #expect(request.text.contains("hello world"))
                #expect(request.sourcePoint == point)
                #expect(view.touchSelection.menuPoint == nil)

                // The host retains the second press so later finger drags
                // extend its native selection. An automatic tap click must
                // not clear that selection or release the held button.
                let surface = try #require(view.surface)
                let size = try #require(surface.size())
                let scale = Double(view.contentScaleFactor)
                let cellWidth = Double(size.cellWidthPixels) / scale
                let cellHeight = Double(size.cellHeightPixels) / scale
                let start = CGPoint(x: cellWidth / 2, y: cellHeight / 2)
                surface.sendMousePos(x: start.x, y: start.y)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
                let selected = try #require(surface.readSelectionResult()?.text)

                view.sendTapClick(at: CGPoint(x: cellWidth * 8.5, y: cellHeight / 2))

                #expect(surface.readSelectionResult()?.text == selected)
                surface.sendMousePos(x: cellWidth * 8.5, y: cellHeight / 2)
                #expect(surface.readSelectionResult()?.text.contains("hello wor") == true)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
                withExtendedLifetime((window, controller, terminalController)) {}
            }
        }

        @MainActor
        private final class HostTextSelectionDelegate: TerminalSurfaceTextSelectionRequestDelegate {
            var requests: [TerminalTextSelectionRequest] = []

            func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
                requests.append(request)
            }
        }
    #endif
#endif
