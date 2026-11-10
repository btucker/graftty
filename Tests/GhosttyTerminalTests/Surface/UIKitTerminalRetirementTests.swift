#if canImport(UIKit)
    import CoreGraphics
    import Foundation
    import QuartzCore
    import UIKit
    import Testing
    @testable import GhosttyTerminal

    @MainActor
    struct UIKitTerminalRetirementTests {
        @Test
        func `temporary UIKit detachment preserves the surface until reattachment`() throws {
            let (window, viewController, terminalView, _) = try makeUIKitTerminal()

            let originalSurface = try #require(terminalView.surface)

            terminalView.removeFromSuperview()

            #expect(terminalView.window == nil)
            #expect(terminalView.surface === originalSurface)

            viewController.view.addSubview(terminalView)

            #expect(terminalView.window === window)
            #expect(terminalView.surface === originalSurface)
        }

        @Test
        func `detached configuration change waits to rebuild until reattachment`() throws {
            let (window, viewController, terminalView, _) = try makeUIKitTerminal()
            let originalSurface = try #require(terminalView.surface)

            terminalView.removeFromSuperview()
            var changedConfiguration = terminalView.configuration
            changedConfiguration.fontSize = 18
            terminalView.configuration = changedConfiguration

            #expect(terminalView.surface === originalSurface)

            viewController.view.addSubview(terminalView)

            #expect(terminalView.window === window)
            #expect(terminalView.surface !== originalSurface)
        }

        @Test
        func `detached controller change keeps old bridge until reattachment`() throws {
            let (window, viewController, terminalView, oldController) = try makeUIKitTerminal()
            let originalSurface = try #require(terminalView.surface)
            let newController = TerminalController()

            #expect(oldController.retainedBridgeCount == 1)
            terminalView.removeFromSuperview()
            terminalView.controller = newController

            #expect(terminalView.surface === originalSurface)
            #expect(oldController.retainedBridgeCount == 1)
            #expect(newController.retainedBridgeCount == 0)

            viewController.view.addSubview(terminalView)

            #expect(terminalView.window === window)
            #expect(terminalView.surface !== originalSurface)
            #expect(oldController.retainedBridgeCount == 0)
            #expect(newController.retainedBridgeCount == 1)
        }

        @Test
        func `surface rebuild clears the session that owned the old surface`() throws {
            let (_, _, terminalView, _) = try makeUIKitTerminal()
            let oldSession = try #require(terminalView.configuration.inMemorySession)
            let newSession = InMemoryTerminalSession(write: { _ in }, resize: { _ in })

            #expect(oldSession.currentSurface != nil)
            terminalView.configuration = .init(backend: .inMemory(newSession))

            #expect(oldSession.currentSurface == nil)
            #expect(newSession.currentSurface == terminalView.surface?.rawValue)
        }

        @Test
        func `transaction retention preserves an existing completion`() async {
            let coordinator = TerminalSurfaceCoordinator()
            var embedderCompletionCount = 0

            CATransaction.begin()
            CATransaction.setCompletionBlock {
                embedderCompletionCount += 1
            }
            coordinator.retainThroughCurrentTransaction()

            #expect(embedderCompletionCount == 0)

            CATransaction.commit()
            CATransaction.flush()
            for _ in 0 ..< 100 where embedderCompletionCount == 0 {
                await Task.yield()
            }

            #expect(embedderCompletionCount == 1)
        }

        @Test
        func `final UIKit teardown survives completion replacement until commit`() async throws {
            weak var retainedView: UITerminalView?
            weak var retainedCoordinator: TerminalSurfaceCoordinator?
            var embedderCompletionCount = 0

            CATransaction.begin()
            do {
                let (_, _, terminalView, _) = try makeUIKitTerminal()
                retainedView = terminalView
                retainedCoordinator = terminalView.core
                terminalView.removeFromSuperview()
            }

            #expect(retainedCoordinator != nil)
            CATransaction.setCompletionBlock {
                embedderCompletionCount += 1
            }
            #expect(retainedCoordinator != nil)

            CATransaction.commit()
            CATransaction.flush()
            for _ in 0 ..< 100 where retainedCoordinator != nil {
                await Task.yield()
            }

            #expect(embedderCompletionCount == 1)
            #expect(retainedView == nil)
            #expect(retainedCoordinator == nil)
        }

        private func makeUIKitTerminal() throws -> (
            window: UIWindow,
            viewController: UIViewController,
            terminalView: UITerminalView,
            controller: TerminalController
        ) {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let viewController = UIViewController()
            let terminalView = UITerminalView(
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
            let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let controller = TerminalController()

            window.rootViewController = viewController
            window.makeKeyAndVisible()
            viewController.view.addSubview(terminalView)
            terminalView.configuration = .init(backend: .inMemory(session))
            terminalView.controller = controller
            _ = try #require(terminalView.surface)

            return (window, viewController, terminalView, controller)
        }
    }
#endif
