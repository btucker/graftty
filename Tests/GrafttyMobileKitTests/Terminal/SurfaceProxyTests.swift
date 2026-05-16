#if canImport(UIKit)
import Testing
import GhosttyTerminal
@testable import GrafttyMobileKit

@Suite
@MainActor
struct SurfaceProxyTests {
    @Test
    func realProxyHandlesNilSurfaceGracefully() {
        // A SurfaceProxy backed by a nil TerminalSurface? should return
        // nil from readSelection and ignore mouse-event calls without
        // crashing — this is the state during pane teardown.
        let proxy = RealSurfaceProxy(surfaceProvider: { nil })
        #expect(proxy.readSelection() == nil)
        proxy.sendLeftMouseDown()       // no-op, no crash
        proxy.sendLeftMouseUp()
        proxy.sendMousePos(x: 0, y: 0)
        #expect(proxy.performAction("select_all") == false)
    }
}
#endif
