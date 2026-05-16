#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@MainActor
final class FakeSurfaceProxy: SurfaceProxy {
    enum Event: Equatable {
        case leftDown
        case leftUp
        case mousePos(Double, Double)
        case action(String)
    }
    var events: [Event] = []
    var selectionText: String?

    @discardableResult func sendLeftMouseDown() -> Bool {
        events.append(.leftDown)
        return true
    }
    @discardableResult func sendLeftMouseUp() -> Bool {
        events.append(.leftUp)
        return true
    }
    func sendMousePos(x: Double, y: Double) {
        events.append(.mousePos(x, y))
    }
    @discardableResult func performAction(_ name: String) -> Bool {
        events.append(.action(name))
        return true
    }
    func readSelection() -> String? { selectionText }
}

@MainActor
final class FakePasteboard: Pasteboard {
    var hasStrings: Bool { string?.isEmpty == false }
    var string: String?
}

@Suite
@MainActor
struct TerminalSelectionControllerTests {

    @Test("""
    @spec IOS-11.2: When the user taps **Select** in the long-press menu, the application shall ask libghostty to word-select the cell under the long-press point by synthesizing a LEFT mouse-down/up pair plus a second click within libghostty's double-click window, and shall enter selection mode for that pane.
    """)
    func beginSelectionSynthesizesDoubleClickAtPointAndActivatesMode() {
        let surface = FakeSurfaceProxy()
        let controller = TerminalSelectionController(surface: surface)

        controller.beginSelection(at: CGPoint(x: 10, y: 20))

        #expect(controller.isActive)
        // Sequence: position, down, up, down, up — two clicks at the same point.
        #expect(surface.events == [
            .mousePos(10, 20),
            .leftDown,
            .leftUp,
            .leftDown,
            .leftUp,
        ])
    }

    @Test("""
    @spec IOS-11.3: When the user taps **Select All** in the long-press menu, the application shall invoke libghostty's `select_all` binding action via `surface.performAction("select_all")` and shall enter selection mode for that pane with the visible viewport highlighted.
    """)
    func selectAllInvokesBindingAndActivatesMode() {
        let surface = FakeSurfaceProxy()
        let controller = TerminalSelectionController(surface: surface)

        controller.selectAll()

        #expect(controller.isActive)
        #expect(surface.events == [.action("select_all")])
    }

    @Test
    func extendForwardsToMousePosOnlyWhenActive() {
        let surface = FakeSurfaceProxy()
        let controller = TerminalSelectionController(surface: surface)

        // Inactive: extend is a no-op.
        controller.extend(to: CGPoint(x: 5, y: 5))
        #expect(surface.events.isEmpty)

        controller.beginSelection(at: CGPoint(x: 0, y: 0))
        let pre = surface.events.count
        controller.extend(to: CGPoint(x: 100, y: 200))
        #expect(surface.events.count == pre + 1)
        #expect(surface.events.last == .mousePos(100, 200))
    }

    @Test("""
    @spec IOS-11.6: When the user taps **Copy**, the application shall extract the active selection via `surface.readSelection()`, write the result to `UIPasteboard.general.string`, clear libghostty's selection, and exit selection mode. If `readSelection()` returns nil or empty, the pasteboard shall not be modified.
    """)
    func copyWritesSelectionToPasteboardAndExitsMode() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = "captured"
        let pb = FakePasteboard()
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)
        surface.events.removeAll()  // ignore begin events for this assertion

        let result = controller.copy(toPasteboard: pb)

        #expect(result == "captured")
        #expect(pb.string == "captured")
        #expect(!controller.isActive)
        #expect(surface.events.contains(.action("clear_selection")))
    }

    @Test
    func copyWithEmptySelectionDoesNotTouchPasteboard() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = ""
        let pb = FakePasteboard()
        pb.string = "untouched"
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)

        _ = controller.copy(toPasteboard: pb)

        #expect(pb.string == "untouched")
        #expect(!controller.isActive)
    }

    @Test
    func copyWithNilSelectionDoesNotTouchPasteboard() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = nil
        let pb = FakePasteboard()
        pb.string = "untouched"
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)

        _ = controller.copy(toPasteboard: pb)

        #expect(pb.string == "untouched")
        #expect(!controller.isActive)
    }

    @Test("""
    @spec IOS-11.7: When the user taps **Cancel**, taps outside the highlighted selection, or presses a key on the terminal control bar while in selection mode, the application shall clear libghostty's selection and exit selection mode without modifying the pasteboard.
    """)
    func cancelClearsSelectionAndExitsModeWithoutPasteboard() {
        let surface = FakeSurfaceProxy()
        surface.selectionText = "would-have-been-copied"
        let pb = FakePasteboard()
        pb.string = "untouched"
        let controller = TerminalSelectionController(surface: surface)
        controller.beginSelection(at: .zero)

        controller.cancel()

        #expect(pb.string == "untouched")
        #expect(!controller.isActive)
        #expect(surface.events.contains(.action("clear_selection")))
    }

    @Test("""
    @spec IOS-11.10: Selection mode shall be per-pane state owned by the focused pane's `TerminalSelectionController`. Selection in one pane shall not affect the selection state of any other pane.
    """)
    func twoControllersHaveIndependentState() {
        let aSurface = FakeSurfaceProxy()
        let bSurface = FakeSurfaceProxy()
        let a = TerminalSelectionController(surface: aSurface)
        let b = TerminalSelectionController(surface: bSurface)

        a.beginSelection(at: .zero)
        #expect(a.isActive)
        #expect(!b.isActive)
        #expect(bSurface.events.isEmpty)
    }
}
#endif
