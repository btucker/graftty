import AppKit
import Testing
@testable import Graftty

@MainActor
struct SurfaceNSViewWindowDragTests {
    @Test("@spec LAYOUT-1.5: When the user drags to select text in a terminal pane beneath the titlebar, the application shall deliver the drag to the terminal instead of moving the window.")
    func terminalMouseDownCannotMoveWindow() {
        _ = NSApplication.shared
        let terminal = SurfaceNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        #expect(!terminal.mouseDownCanMoveWindow)
    }
}
