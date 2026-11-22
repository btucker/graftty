#if canImport(UIKit) && !targetEnvironment(macCatalyst)
@testable import GhosttyTerminal
import GhosttyKit
import Testing
@testable import GrafttyMobileKit
import UIKit

/// A long press already in `.began` at a point a test chooses.
final class ScriptedLongPress: UILongPressGestureRecognizer {
    var point: CGPoint = .zero
    override var state: UIGestureRecognizer.State { get { .began } set {} }
    override func location(in _: UIView?) -> CGPoint { point }
}

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

    @Test("@spec IOS-11.6: When the user chooses Copy from a mobile terminal selection menu, the application shall write the selected text to the pasteboard and clear the selection; if nothing is selected, then the pasteboard shall not be modified.")
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

    @Test
    func hostSuppliesTheSelectionMenu() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view
        var menuText: String?
        view.selectionMenuItems = { context in
            menuText = context.selectedText
            return [UIAction(title: "Probe") { _ in }]
        }
        let point = try harness.point(column: 7, row: 0)
        try #require(view.beginHostTouchSelection(at: point))

        let menu = view.touchSelectionMenu(at: point, suggestedActions: [])

        #expect(menu.children.compactMap { ($0 as? UIAction)?.title } == ["Probe"])
        #expect(menuText == "beta")
    }

    @Test("@spec IOS-11.5: When the user finishes dragging a selection handle on mobile, the application shall present the edit menu clear of the selection and its handles.")
    func menuAfterAHandleDragAvoidsTheSelection() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view
        let point = try harness.point(column: 7, row: 0)
        try #require(view.beginHostTouchSelection(at: point))
        let overlay = try #require(view.touchSelection.overlay)

        view.finishTouchSelectionDrag(at: point)

        let avoid = try #require(overlay.menuAvoidanceRect)
        #expect(!avoid.isEmpty)
        #expect(view.touchMenuTargetRect(at: point) == avoid)
        #expect(view.hasTouchSelection)
    }

    @Test("@spec IOS-11.1: When the user presses and holds terminal text on mobile, the application shall select the word under the press, show a handle at each end of the selection, and present an edit menu containing Copy, Select All, and Paste when the clipboard holds text or an image, without synthesizing mouse input.")
    func longPressSelectsTheWordWithHandles() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view
        let press = ScriptedLongPress()
        press.point = try harness.point(column: 7, row: 0)

        view.handleLongPressForSelection(press)

        #expect(view.hasTouchSelection)
        #expect(view.touchSelectionText == "beta")
        let overlay = try #require(view.touchSelection.overlay)
        #expect(!overlay.startHandle.isHidden)
        #expect(!overlay.endHandle.isHidden)
        #expect(view.surface?.hasSelection() == false)
        #expect(harness.container.longPressSelectedText == "beta")
        #expect(harness.container.selectionMenuActionTitlesForTesting(hasPasteContent: false) == ["Copy", "Select All"])
        #expect(harness.container.selectionMenuActionTitlesForTesting(hasPasteContent: true) == ["Copy", "Select All", "Paste"])
        let menu = view.touchSelectionMenu(at: press.point, suggestedActions: [])
        #expect(menu.children.compactMap { ($0 as? UIAction)?.title }.prefix(2) == ["Copy", "Select All"])
    }

    @Test("@spec IOS-11.2: If the user presses and holds a blank region of a mobile terminal with no text nearby, then the application shall present Select All and Paste without creating a selection.")
    func blankLongPressFallsBackToPlainMenu() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        let press = ScriptedLongPress()
        press.point = try harness.point(column: 3, row: 2)

        harness.view.handleLongPressForSelection(press)

        #expect(!harness.view.hasTouchSelection)
        #expect(harness.container.longPressSelectedText == nil)
        #expect(harness.container.longPressMenuActionTitlesForTesting(hasPasteContent: true) == ["Select All", "Paste"])
        #expect(harness.container.longPressMenuActionTitlesForTesting(hasPasteContent: false) == ["Select All"])
    }

    @Test("@spec IOS-11.3: When the user chooses Select All from a mobile terminal menu, the application shall select all terminal text including scrollback and show its handles.")
    func selectAllCoversScrollback() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        let lines = (0..<200).map { "line \($0)" }.joined(separator: "\r\n")
        try await harness.show("first words\r\n" + lines, until: "line 199")
        let view = harness.view
        // The scrollbar, which bounds Select All, is published on a tick.
        try await harness.waitForViewportOffset { $0 > 100 }
        let press = ScriptedLongPress()
        press.point = try harness.point(column: 1, row: 3)
        view.handleLongPressForSelection(press)
        try #require(view.hasTouchSelection)
        let selectAll = try #require(view.touchSelectionMenu(at: press.point, suggestedActions: [])
            .children.compactMap { $0 as? UIAction }.first { $0.title == "Select All" })

        let button = UIButton()
        button.addAction(selectAll, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        // The library selects once its menu has finished dismissing.
        let pending = try #require(view.touchSelection.pendingAction)
        view.touchSelection.pendingAction = nil
        pending()

        let text = try #require(view.touchSelectionText)
        #expect(text.hasPrefix("first words"))
        #expect(text.contains("line 199"))
        #expect(view.touchSelection.overlay != nil)
    }

    @Test("@spec IOS-11.7: When the user taps outside a mobile terminal selection or presses a terminal control-bar key, the application shall clear the selection without modifying the pasteboard.")
    func controlBarKeyClearsTheSelection() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("alpha beta gamma", until: "gamma")
        let view = harness.view
        try #require(view.beginHostTouchSelection(at: try harness.point(column: 7, row: 0)))

        harness.container.cancelActiveSelectionIfAny()

        #expect(!view.hasTouchSelection)
        #expect(view.touchSelection.overlay == nil)
        try #require(view.beginHostTouchSelection(at: try harness.point(column: 7, row: 0)))
        #expect(view.dismissTouchSelectionForTap())
        #expect(!view.hasTouchSelection)
    }

    @Test("@spec IOS-11.10: A mobile terminal selection shall belong to its own pane and shall not affect the selection of any other pane.")
    func selectionIsPerPane() async throws {
        let first = try await TouchSelectionHarness()
        defer { first.tearDown() }
        let second = try await TouchSelectionHarness()
        defer { second.tearDown() }
        try await first.show("alpha beta gamma", until: "gamma")
        try await second.show("delta epsilon", until: "epsilon")

        try #require(first.view.beginHostTouchSelection(at: try first.point(column: 7, row: 0)))
        #expect(!second.view.hasTouchSelection)
        try #require(second.view.beginHostTouchSelection(at: try second.point(column: 1, row: 0)))
        first.container.cancelActiveSelectionIfAny()

        #expect(!first.view.hasTouchSelection)
        #expect(second.view.touchSelectionText == "delta")
    }

    @Test
    func linkActionsDropAfterSelectionChanges() async throws {
        let harness = try await TouchSelectionHarness()
        defer { harness.tearDown() }
        try await harness.show("see https://example.com/docs now", until: "now")
        let view = harness.view
        let container = harness.container
        container.hostLabel = "Studio"
        let press = ScriptedLongPress()
        press.point = try harness.point(column: 10, row: 0)

        view.handleLongPressForSelection(press)

        try #require(view.hasTouchSelection)
        #expect(container.selectionMenuActionTitlesForTesting(hasPasteContent: false) == [
            "Open Link", "Open on Studio", "Copy Link", "Copy", "Select All",
        ])
        // A handle drag changes the selection; the link belonged to the pressed word.
        let changed = TerminalTouchSelectionMenuContext(sourcePoint: press.point, selectedText: "see https")
        let titles = container.selectionMenuElements(for: changed, hasPasteContent: false)
            .compactMap { ($0 as? UIAction)?.title }
        #expect(titles == ["Copy", "Select All"])
    }
}
#endif
