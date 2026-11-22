#if canImport(UIKit) && !targetEnvironment(macCatalyst)
@testable import GhosttyTerminal
import GhosttyKit
import Testing
@testable import GrafttyMobileKit
import UIKit

/// A pan whose state and location a test sets directly.
final class ScriptedPan: UIPanGestureRecognizer {
    var scriptedState: UIGestureRecognizer.State = .began
    var point: CGPoint = .zero
    var touches = 1
    override var state: UIGestureRecognizer.State { get { scriptedState } set {} }
    override var numberOfTouches: Int { touches }
    override func location(in _: UIView?) -> CGPoint { point }
    override func translation(in _: UIView?) -> CGPoint { .zero }
    override func velocity(in _: UIView?) -> CGPoint { .zero }
}

/// A real terminal surface inside a `TerminalInputContainerView`, the way
/// GrafttyMobile mounts one: the container is the host selection delegate.
@MainActor
final class TouchSelectionHarness {
    private final class Responses: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        func contains(_ text: String) -> Bool { lock.withLock { data.range(of: Data(text.utf8)) != nil } }
    }

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    let container: TerminalInputContainerView
    let session: InMemoryTerminalSession
    var view: MobileTerminalInputView { container.terminalView }

    init() async throws {
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        container = TerminalInputContainerView(frame: window.bounds)
        let responses = Responses()
        session = InMemoryTerminalSession(write: { responses.append($0) }, resize: { _ in })
        container.terminalView.configuration = .init(backend: .inMemory(session))
        container.terminalView.controller = MobileTerminalControllerFactory.make(configText: "font-size = 14")
        host.view.addSubview(container)
        container.layoutIfNeeded()
        let grid = try #require(container.terminalGridMetrics)
        // The parser resizes after the public metrics arrive; a cursor
        // clamped to the bottom-right proves it reached this grid.
        let bottomRight = "\u{1b}[\(grid.rows);\(grid.columns)R"
        for _ in 0..<100 where !responses.contains(bottomRight) {
            session.receive("\u{1b}[999;999H\u{1b}[6n")
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(responses.contains(bottomRight))
        session.receive("\u{1b}[H\u{1b}[2J")
    }

    func tearDown() {
        container.removeFromSuperview()
        window.isHidden = true
    }

    /// Feeds output and waits until the viewport shows `marker`.
    func show(_ output: String, until marker: String) async throws {
        session.receive(output)
        for _ in 0..<200 where session.readViewportText()?.contains(marker) != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.readViewportText()?.contains(marker) == true)
    }

    /// The centre of the viewport cell at `column`, `row`, in view points.
    func point(column: Int, row: Int) throws -> CGPoint {
        let grid = try #require(view.touchSelectionGrid())
        let rect = grid.rect(for: (row + view.touchViewportOffset) * grid.columns + column,
                             viewportOffset: view.touchViewportOffset)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func waitForViewportOffset(_ matches: (Int) -> Bool) async throws {
        for _ in 0..<200 where !matches(view.touchViewportOffset) {
            view.controller?.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(matches(view.touchViewportOffset))
    }
}

@MainActor
@Suite(.serialized)
struct TerminalTouchSelectionTests {
    @Test
    func hostCanBeginTouchSelectionWithHandles() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view

        let began = view.beginHostTouchSelection(at: try harness.point(column: 7, row: 0))

        #expect(began)
        #expect(view.hasTouchSelection)
        #expect(view.touchSelectionText == "beta")
        let overlay = try #require(view.touchSelection.overlay)
        #expect(!overlay.startHandle.isHidden)
        #expect(!overlay.endHandle.isHidden)
        #expect(view.surface?.hasSelection() == false, "Touch selection must not use Ghostty's mouse selection")
    }

    @Test
    func blankPointBeginsNothing() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        let view = harness.view

        #expect(!view.beginHostTouchSelection(at: try harness.point(column: 3, row: 2)))
        #expect(!view.hasTouchSelection)
        #expect(view.touchSelectionText == nil)
    }

    @Test
    func scrollKeepsHostTouchSelection() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        let lines = (0..<200).map { "line \($0)" }.joined(separator: "\r\n")
        try await harness.show("alpha beta gamma\r\n" + lines, until: "line 199")
        let view = harness.view
        let surface = try #require(view.surface)
        _ = surface.scrollToRow(0)
        try await harness.waitForViewportOffset { $0 == 0 }
        try #require(view.beginHostTouchSelection(at: try harness.point(column: 7, row: 0)))
        let overlay = try #require(view.touchSelection.overlay)

        let pan = ScriptedPan()
        view.handleTouchScrollGesture(pan)
        #expect(view.hasTouchSelection, "Starting a one-finger scroll must not drop the selection")

        _ = surface.scrollToRow(50)
        try await harness.waitForViewportOffset { $0 == 50 }
        view.refreshTouchSelection()
        #expect(view.touchSelectionText == "beta")
        #expect(overlay.startHandle.isHidden)
        #expect(overlay.endHandle.isHidden)

        _ = surface.scrollToRow(0)
        try await harness.waitForViewportOffset { $0 == 0 }
        view.refreshTouchSelection()
        #expect(view.touchSelectionText == "beta")
        #expect(!overlay.startHandle.isHidden)
        #expect(!overlay.endHandle.isHidden)
    }

    @Test
    func redrawUnderHostTouchSelectionDismissesIt() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view
        try #require(view.beginHostTouchSelection(at: try harness.point(column: 7, row: 0)))

        try await harness.show("\u{1b}[2J\u{1b}[Hzzzzzzzzzzzzzzzz", until: "zzzz")
        view.touchSelection.lastValidation = 0
        view.refreshTouchSelection()

        #expect(!view.hasTouchSelection)
    }

    @Test
    func tapDismissesHostTouchSelectionWithoutTogglingKeyboard() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view
        try #require(view.beginHostTouchSelection(at: try harness.point(column: 7, row: 0)))
        let keyboardWasVisible = view.softwareKeyboard.isVisible

        let consumed = view.dismissTouchSelectionForTap()

        #expect(consumed, "The tap belongs to the selection, not to the keyboard or the program")
        #expect(!view.hasTouchSelection)
        #expect(view.softwareKeyboard.isVisible == keyboardWasVisible)
        #expect(!view.dismissTouchSelectionForTap(), "With nothing selected a tap stays an ordinary tap")
    }

    @Test
    func copyTouchSelectionTakesTheSelectionDown() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view
        try #require(view.beginHostTouchSelection(at: try harness.point(column: 7, row: 0)))

        // The hostless test runner may not read the pasteboard back.
        #expect(view.copyTouchSelection())

        #expect(!view.hasTouchSelection)
        #expect(!view.copyTouchSelection(), "Nothing selected, nothing copied")
    }
}
#endif
