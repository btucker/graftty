#if canImport(UIKit)
import CoreGraphics

/// IOS-11.x: per-pane selection state machine. Drives libghostty's
/// native selection through a `SurfaceProxy`, extracts selection text
/// via `SurfaceProxy.readSelection`, writes to a `Pasteboard`. Pure
/// logic — no UIKit imports beyond `CGPoint` (CoreGraphics).
@MainActor
public final class TerminalSelectionController {
    public private(set) var isActive: Bool = false
    private let surface: SurfaceProxy

    public init(surface: SurfaceProxy) {
        self.surface = surface
    }

    /// IOS-11.2: word-select via synthesized double-click at `point`.
    public func beginSelection(at point: CGPoint) {
        surface.sendMousePos(x: Double(point.x), y: Double(point.y))
        // Two left-clicks at the same point — libghostty's mouse handler
        // promotes back-to-back presses within its double-click window
        // to word-select semantics.
        surface.sendLeftMouseDown()
        surface.sendLeftMouseUp()
        surface.sendLeftMouseDown()
        surface.sendLeftMouseUp()
        isActive = true
    }

    /// IOS-11.3: full-viewport select via libghostty's `select_all` binding.
    public func selectAll() {
        surface.performAction("select_all")
        isActive = true
    }

    /// IOS-11.4: forward pan to libghostty's mouse-position handler,
    /// which extends the current selection while the LEFT button
    /// remains pressed in libghostty's view. (Our two-press begin
    /// leaves no button held, so for v1 we treat `extend` as
    /// shift-click: hold shift via mods? — TODO at integration time
    /// if drag-extend doesn't visibly extend on-device. Initial impl
    /// uses plain sendMousePos; we'll revisit with a real surface.)
    public func extend(to point: CGPoint) {
        guard isActive else { return }
        surface.sendMousePos(x: Double(point.x), y: Double(point.y))
    }

    /// IOS-11.6: extract + clipboard + clear + exit. Returns the copied
    /// text (or nil if there was nothing to copy).
    @discardableResult
    public func copy(toPasteboard pb: Pasteboard) -> String? {
        defer { exit() }
        guard let text = surface.readSelection(), !text.isEmpty else {
            return nil
        }
        var pb = pb
        pb.string = text
        return text
    }

    /// IOS-11.7: clear libghostty's selection and exit mode without
    /// touching the pasteboard.
    public func cancel() {
        exit()
    }

    private func exit() {
        surface.performAction("clear_selection")
        isActive = false
    }
}
#endif
