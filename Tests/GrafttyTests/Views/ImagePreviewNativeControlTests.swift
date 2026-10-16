import AppKit
import XCTest
import GrafttyKit
@testable import Graftty

/// Native control tracking runs in XCTest's AppKit process.
@MainActor
final class ImagePreviewNativeControlTests: XCTestCase {
    /// @spec IMAGE-1.18: When the user clicks the native preview tray navigation or Close controls, the application shall perform that action without starting a header drag, and restore terminal focus when closing a focused preview.
    func testNativeZoomFitAndCloseTargets() throws {
        for width in [800.0, 180] { try assertNativeTargets(trayWidth: width) }
    }

    private func assertNativeTargets(trayWidth: CGFloat) throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = NativePreviewTerminal(frame: root.bounds)
        root.addSubview(terminal)
        window.contentView = root
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        var dismissed = 0, interactions = 0
        let tray = NativeFilePreviewTray(preview: try .init(image: image, filename: "chart.png"), onDismiss: { dismissed += 1 },
                                          onInteraction: { _ in interactions += 1 })
        defer { tray.tearDown() }
        tray.frame = NSRect(x: 0, y: 330, width: trayWidth, height: 270)
        root.addSubview(tray)
        tray.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertFalse(tray.previous.isEnabled)
        XCTAssertFalse(tray.next.isEnabled)
        tray.claimFocus()
        XCTAssertTrue(tray.ownsFocus)
        let close = try XCTUnwrap(descendants(tray).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Close preview" })
        try click(close, at: NSPoint(x: close.bounds.midX, y: close.bounds.midY), window: window)
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(interactions, 0)
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertEqual(terminal.bounds.size, NSSize(width: 800, height: 600))
    }

    private func click(_ view: NSView, at point: NSPoint, window: NSWindow) throws {
        let location = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApp.finishLaunching()
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

@MainActor
private final class NativePreviewTerminal: NSView {
    override var acceptsFirstResponder: Bool { true }
}
