#if canImport(UIKit)
import GhosttyTerminal

/// A narrow facade over `TerminalSurface`'s selection-driving methods,
/// so `TerminalSelectionController` can be tested without a real
/// libghostty surface.
@MainActor
public protocol SurfaceProxy {
    @discardableResult func sendLeftMouseDown() -> Bool
    @discardableResult func sendLeftMouseUp() -> Bool
    func sendMousePos(x: Double, y: Double)
    @discardableResult func performAction(_ name: String) -> Bool
    func readSelection() -> String?
}

/// Real adapter used in production. The surface is looked up lazily
/// per-call because a `UITerminalView`'s surface may be rebuilt during
/// a pane's lifetime (e.g., size-leader changes), so capturing a
/// reference at init time would dangle.
@MainActor
public final class RealSurfaceProxy: SurfaceProxy {
    private let surfaceProvider: () -> TerminalSurface?

    public init(surfaceProvider: @escaping () -> TerminalSurface?) {
        self.surfaceProvider = surfaceProvider
    }

    @discardableResult
    public func sendLeftMouseDown() -> Bool {
        surfaceProvider()?.sendLeftMouseDown() ?? false
    }

    @discardableResult
    public func sendLeftMouseUp() -> Bool {
        surfaceProvider()?.sendLeftMouseUp() ?? false
    }

    public func sendMousePos(x: Double, y: Double) {
        surfaceProvider()?.sendMousePos(x: x, y: y)
    }

    @discardableResult
    public func performAction(_ name: String) -> Bool {
        surfaceProvider()?.performAction(name) ?? false
    }

    public func readSelection() -> String? {
        surfaceProvider()?.readSelection()
    }
}
#endif
