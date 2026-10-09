import CoreGraphics
import Foundation
import Testing
@testable import GrafttyMobileKit

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import GhosttyTerminal
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import UIKit
#endif

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
@Suite("@spec IOS-4.8: While a mobile terminal is displayed fullscreen, the application shall extend its usable terminal viewport to the top and bottom screen edges, keep floating controls within the safe area, and reserve only the keyboard and its control bar when the keyboard is visible.", .serialized)
@MainActor
struct RenderedTerminalViewportTests {
    @Test("@spec IOS-6.11: While the software keyboard is visible in a fullscreen mobile terminal, the application shall reserve the measured terminal control-bar height above the keyboard; while the keyboard is hidden, floating controls shall overlay the full usable viewport.", arguments: [CGFloat(0), CGFloat(300)])
    func fullscreenCanvasReachesScreenEdges(keyboardInset: CGFloat) async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        client.start()
        defer { client.stop() }
        try await waitForLayout("local owner") { client.isOwner }
        let fixture = makeFixture(client: client, keyboardInset: keyboardInset)
        defer { fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        let containerFrame = container.convert(container.bounds, to: fixture.window)
        let canvasFrame = container.snapshotScrollView.convert(container.snapshotScrollView.bounds, to: fixture.window)
        // The control bar has 34pt controls, 16pt vertical content padding,
        // and 8pt bottom padding. Hidden controls float over the full canvas.
        let expectedBottom = fixture.window.bounds.maxY - keyboardInset - (keyboardInset > 0 ? 58 : 0)

        #expect(abs(containerFrame.minY - fixture.window.bounds.minY) < 1,
                "Terminal container starts at \(containerFrame.minY), screen starts at \(fixture.window.bounds.minY)")
        #expect(abs(containerFrame.maxY - expectedBottom) < 1,
                "Terminal container ends at \(containerFrame.maxY), expected \(expectedBottom)")
        #expect(abs(canvasFrame.minY - fixture.window.bounds.minY) < 1,
                "Canvas viewport starts at \(canvasFrame.minY), leaving a top gap")
        #expect(abs(canvasFrame.maxY - expectedBottom) < 1,
                "Canvas viewport ends at \(canvasFrame.maxY), expected \(expectedBottom)")
        #expect(abs(containerFrame.width - fixture.window.bounds.width) < 1)
        #expect(abs(canvasFrame.width - fixture.window.bounds.width) < 1)
    }

    @Test
    func embeddedCanvasStaysInsideTheIPadDetailColumn() async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        let fixture = makeFixture(client: client, embedded: true)
        defer { client.stop(); fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        let containerFrame = container.convert(container.bounds, to: fixture.window)
        let canvasFrame = container.snapshotScrollView.convert(container.snapshotScrollView.bounds, to: fixture.window)

        #expect(abs(containerFrame.minX - 320) < 1)
        #expect(abs(containerFrame.maxX - fixture.window.bounds.maxX) < 1)
        #expect(abs(canvasFrame.minX - containerFrame.minX) < 1)
        #expect(abs(canvasFrame.maxX - containerFrame.maxX) < 1)
        #expect(canvasFrame.minY > containerFrame.minY)
        #expect(canvasFrame.maxY < containerFrame.maxY)
    }

    @Test("@spec IOS-5.5: While a terminal is fullscreen, the application shall display a translucent Back control with at least a 44-point tap target within the top and leading safe area, returning to the worktree list.")
    func floatingBackControlStaysBelowTheTopSafeArea() async throws {
        let fixture = makeHostingFixture(content: AnyView(GeometryReader { _ in
            Color.black.ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    TerminalFloatingGlyphButton(systemName: "chevron.left",
                                                accessibilityLabel: "Back to worktrees", action: {})
                        .background(FloatingControlFrameMarker())
                        .modifier(TerminalFloatingControlPlacement())
                }
        }))
        defer { fixture.window.isHidden = true }
        var markers: [FloatingControlFrameView] = []
        try await waitForLayout("floating Back geometry") {
            fixture.host.view.layoutIfNeeded()
            markers = descendants(of: fixture.host.view).compactMap { $0 as? FloatingControlFrameView }
            return markers.count == 1 && markers[0].bounds.width > 0 && markers[0].bounds.height > 0
        }
        let marker = try #require(markers.first)
        let backFrame = marker.convert(marker.bounds, to: fixture.window)
        let safeTop = fixture.host.view.safeAreaInsets.top
        let safeLeading = fixture.host.view.safeAreaInsets.left

        #expect(safeTop >= 40, "The rendered fixture must have a real top safe area")
        #expect(abs(backFrame.minY - (safeTop + 12)) < 1,
                "Back starts at \(backFrame.minY), expected 12pt below the safe area at \(safeTop)")
        #expect(abs(backFrame.minX - (safeLeading + 12)) < 1,
                "Back starts at \(backFrame.minX), expected 12pt after the leading safe area at \(safeLeading)")
        #expect(backFrame.width >= 44 && backFrame.height >= 44,
                "Back's rendered control is \(backFrame.size), below the 44pt minimum tap target")
        #expect(fixture.window.bounds.contains(backFrame))
    }

    private func makeFixture(client: SessionClient, keyboardInset: CGFloat = 0,
                             embedded: Bool = false) -> (window: UIWindow, host: UIHostingController<AnyView>) {
        let terminal = SingleSessionView(
            step: SessionStep(host: Host(label: "Mac", baseURL: URL(string: "https://mac.local")!),
                              sessionName: "viewport", title: "Shell"),
            navigationPath: .constant(NavigationPath()), isFullScreen: !embedded,
            isEmbeddedPane: embedded, initialClient: client,
            initialController: MobileTerminalControllerFactory.make(configText: "font-size = 14"),
            initialKeyboardBottomInset: keyboardInset)
        let content: AnyView
        if embedded {
            content = AnyView(HStack(spacing: 0) {
                Color.gray.frame(width: 320)
                terminal.frame(maxWidth: .infinity, maxHeight: .infinity)
            })
        } else {
            content = AnyView(terminal)
        }
        return makeHostingFixture(content: content, embedded: embedded)
    }

    private func makeHostingFixture(content: AnyView,
                                    embedded: Bool = false) -> (window: UIWindow, host: UIHostingController<AnyView>) {
        let host = UIHostingController(rootView: AnyView(content
            .environment(\.scenePhase, .inactive)
            .environment(\.horizontalSizeClass, embedded ? .regular : .compact)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: embedded ? 834 : 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let nativeInsets = host.view.safeAreaInsets
        host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, 59 - nativeInsets.top), left: 0,
                                                     bottom: max(0, 34 - nativeInsets.bottom), right: 0)
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func renderedContainer(in root: UIView) async throws -> TerminalInputContainerView {
        var container: TerminalInputContainerView?
        try await waitForLayout("measured terminal cells") {
            root.layoutIfNeeded()
            container = descendants(of: root).compactMap { $0 as? TerminalInputContainerView }.first
            container?.layoutIfNeeded()
            guard let metrics = container?.terminalGridMetrics else { return false }
            return metrics.columns > 0 && metrics.rows > 0 && metrics.cellHeightPixels > 0
                && container!.snapshotScrollView.bounds.height > 0
        }
        // Let the resize callback's resulting layout settle before measuring.
        try await Task.sleep(for: .milliseconds(100))
        root.layoutIfNeeded()
        container?.layoutIfNeeded()
        return try #require(container)
    }

    private func descendants(of root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private func waitForLayout(_ stage: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Timed out waiting for \(stage)")
    }
}

private final class FloatingControlFrameView: UIView {}

private struct FloatingControlFrameMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> FloatingControlFrameView {
        let view = FloatingControlFrameView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: FloatingControlFrameView, context: Context) {}
}

private final class ViewportLegacySocket: WebSocketClient, @unchecked Sendable {
    func send(_ frame: WebSocketFrame) async throws {}
    func receive() async throws -> WebSocketFrame {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
    func close() {}
}

@Suite("""
@spec IOS-6.1: While the software keyboard is visible, the application shall render a compact terminal control bar above the keyboard with Esc, Tab, sticky Ctrl, Ctrl-C, Ctrl-D, arrows, submit Return, literal LF, and Hide Keyboard controls. The non-modifier controls shall send their explicit terminal bytes through `SessionClient`. Tapping sticky Ctrl once shall arm it for the next software-keyboard letter, tapping it twice shall lock it, and libghostty shall translate Ctrl+A through Ctrl+Z to ASCII bytes `0x01` through `0x1A`. When terminal input becomes ineligible, the application shall clear sticky Ctrl state.
""")
@MainActor
struct MobileTerminalControlBarTests {
    @Test("the control bar keeps Tab visible and puts sticky Ctrl beside it")
    func layoutContainsTabAndStickyControl() {
        #expect(SingleSessionView.terminalControlBarItems == [
            .escape,
            .tab,
            .stickyControl,
            .controlC,
            .controlD,
            .navigationDivider,
            .left,
            .down,
            .up,
            .right,
            .returnDivider,
            .submitReturn,
            .literalLineFeed,
            .hideKeyboard,
        ])
    }

    @Test("sticky Ctrl uses libghostty for arbitrary software-keyboard letters")
    func stickyControlLettersSendAsciiControlBytes() {
        let recorder = ThreadSafeDataRecorder()
        let session = InMemoryTerminalSession(
            write: { recorder.append($0) },
            resize: { _ in }
        )
        let container = TerminalInputContainerView(frame: .zero)
        container.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        var activations: [TerminalInputContainerView.StickyControlActivation] = []
        container.setStickyControlActivationChangeHandler { activations.append($0) }

        container.toggleStickyControlModifier()
        #expect(container.stickyControlActivation == .armed)
        container.terminalView.insertText("a")
        #expect(container.stickyControlActivation == .inactive)

        container.toggleStickyControlModifier()
        container.terminalView.insertText("j")

        container.toggleStickyControlModifier()
        container.terminalView.insertText("z")

        #expect(recorder.values == [Data([0x01]), Data([0x0A]), Data([0x1A])])
        #expect(activations == [
            .armed, .inactive,
            .armed, .inactive,
            .armed, .inactive,
        ])
    }

    @Test("normal typing does not disconnect the sticky Ctrl state observer")
    func ordinaryTextKeepsStickyControlObserverAttached() {
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        var activations: [TerminalInputContainerView.StickyControlActivation] = []
        container.setStickyControlActivationChangeHandler { activations.append($0) }

        container.terminalView.insertText("x")
        container.toggleStickyControlModifier()

        #expect(activations == [.armed])
        #expect(container.stickyControlActivation == .armed)
    }

    @Test("double-tapping sticky Ctrl locks it until reset")
    func stickyControlDoubleTapLocks() {
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        // The renderer uses a real 300 ms double-tap window and exposes no
        // clock override. A simulator can preempt these synchronous calls
        // long enough to produce two single taps. Retry only that measured
        // case, never an incorrect transition inside the double-tap window.
        for attempt in 0..<5 {
            container.resetStickyModifiers()
            let start = ContinuousClock.now
            container.toggleStickyControlModifier()
            container.toggleStickyControlModifier()
            let elapsed = start.duration(to: .now)
            if elapsed >= .milliseconds(300),
               container.stickyControlActivation == .inactive,
               attempt < 4 {
                continue
            }
            break
        }
        #expect(container.stickyControlActivation == .locked)

        container.committedSoftwareInput = nil
        #expect(container.stickyControlActivation == .inactive)

        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        container.toggleStickyControlModifier()
        container.resetStickyModifiers()
        #expect(container.stickyControlActivation == .inactive)
    }
}

private final class ThreadSafeDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ value: Data) {
        lock.withLock { storage.append(value) }
    }
}
#endif
