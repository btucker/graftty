import AppKit
import Foundation
import Testing
import SwiftUI
@testable import Graftty
import GrafttyKit

@MainActor
struct ImagePreviewControlTests {
    @Test("@spec IMAGE-1.16: When the user drags the image tray header, corner grip, or bottom edge, the application shall move or resize the tray within the terminal content bounds while retaining usable controls and an unobscured terminal region, without resizing the terminal grid.")
    func movementAndResizeStayWithinTerminal() {
        let viewport = CGSize(width: 800, height: 600)
        let frame = CGRect(x: 100, y: 50, width: 500, height: 270)
        let moved = ImagePreviewGeometry.moving(frame, by: CGSize(width: 1000, height: 1000), in: viewport)
        #expect(moved == CGRect(x: 300, y: 330, width: 500, height: 270))
        let up = ImagePreviewGeometry.moving(frame, by: CGSize(width: -1000, height: -1000), in: viewport)
        #expect(up.origin == .zero)
        let enlarged = ImagePreviewGeometry.resizing(frame, by: CGSize(width: 1000, height: 1000), in: viewport)
        #expect(enlarged.maxX <= viewport.width)
        #expect(enlarged.maxY <= viewport.height)
        #expect(enlarged.height <= viewport.height - 96)
        let small = ImagePreviewGeometry.resizing(frame, by: CGSize(width: -1000, height: -1000), in: viewport)
        #expect(small.width >= 320)
        #expect(small.height >= 120)
        let resizedWindow = ImagePreviewGeometry.constrained(frame, in: CGSize(width: 360, height: 260))
        #expect(resizedWindow.maxX <= 360 && resizedWindow.maxY <= 260)
    }

    @Test("@spec IMAGE-1.17: While a user moves or resizes the image tray through pointer input, the application shall keep its native controls operable and allow clicks outside the tray to reach the unchanged terminal surface.")
    func pointerInputMovesAndResizesWithoutBlockingTerminal() async throws {
        _ = NSApplication.shared
        let terminal = ImagePreviewControlTerminal(frame: .zero)
        let pane = PaneSlotID(id: UUID())
        let preview = try ImagePreviewStore.Preview(image: try fixture(), filename: "drag me.png")
        func root(pane: PaneSlotID, preview: ImagePreviewStore.Preview?) -> some View {
            ImagePreviewControlTerminalView(view: terminal).overlay(alignment: .top) {
                ImagePreviewOverlay(pane: pane, preview: preview, onDismiss: {})
            }
        }
        let hosted = NSHostingView(rootView: root(pane: pane, preview: preview))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        let tray = try #require(descendants(hosted).compactMap { $0 as? NativeFilePreviewTray }.first)
        let resizePoint = tray.grip.convert(NSPoint(x: 12, y: 12), to: nil)
        let grip = try #require(hosted.hitTest(hosted.superview?.convert(resizePoint, from: nil) ?? resizePoint))
        #expect(grip === tray.grip)
        try drag(grip, from: resizePoint, to: NSPoint(x: resizePoint.x - 200, y: resizePoint.y - 60), window: window)
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        #expect(tray.bounds.size == CGSize(width: 600, height: 330))
        let bottomPoint = tray.convert(NSPoint(x: tray.bounds.midX, y: 4), to: nil)
        let bottom = try #require(hosted.hitTest(hosted.superview?.convert(bottomPoint, from: nil) ?? bottomPoint))
        try #require(bottom.accessibilityLabel() == "Resize preview height")
        try drag(bottom, from: bottomPoint, to: NSPoint(x: bottomPoint.x + 100, y: bottomPoint.y - 60), window: window)
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        #expect(tray.bounds.size == CGSize(width: 600, height: 390))
        let headerPoint = tray.header.convert(NSPoint(x: 40, y: 22), to: nil)
        let header = try #require(hosted.hitTest(hosted.superview?.convert(headerPoint, from: nil) ?? headerPoint))
        try drag(header, from: headerPoint, to: NSPoint(x: headerPoint.x + 100, y: headerPoint.y - 100), window: window)
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        let positioned = hosted.convert(tray.bounds, from: tray)
        #expect(positioned.minX == 100)
        #expect(positioned.minY == 100)
        #expect(terminal.bounds.size == CGSize(width: 800, height: 600))
        let outside = terminal.convert(NSPoint(x: 760, y: 40), to: hosted.superview)
        let hit = try #require(hosted.hitTest(outside))
        #expect(hit === terminal || hit.isDescendant(of: terminal))
        let zoomPoint = tray.picker.convert(NSPoint(x: tray.picker.bounds.midX, y: tray.picker.bounds.midY), to: nil)
        let zoomHit = try #require(hosted.hitTest(hosted.superview?.convert(zoomPoint, from: nil) ?? zoomPoint))
        #expect(zoomHit === tray.picker || zoomHit.isDescendant(of: tray.picker))

        window.setContentSize(CGSize(width: 360, height: 260))
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        let shrunkFrame = hosted.convert(tray.bounds, from: tray)
        #expect(shrunkFrame.minX >= 0 && shrunkFrame.minY >= 0)
        #expect(shrunkFrame.maxX <= 360 && shrunkFrame.maxY <= 260)
        #expect(terminal.bounds.size == CGSize(width: 360, height: 260))

        // A different pane/worktree must not inherit this pane's tray or position.
        let otherPane = PaneSlotID(id: UUID())
        hosted.rootView = root(pane: otherPane, preview: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(descendants(hosted).compactMap { $0 as? NativeFilePreviewTray }.isEmpty)
        hosted.rootView = root(pane: otherPane, preview: try .init(image: try fixture(), filename: "other worktree.png"))
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        let otherTray = try #require(descendants(hosted).compactMap { $0 as? NativeFilePreviewTray }.first)
        #expect(otherTray !== tray)
        #expect(hosted.convert(otherTray.bounds, from: otherTray).origin == .zero)
        #expect(otherTray.bounds.width == 360)
        window.setContentSize(CGSize(width: 180, height: 260))
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        #expect(otherTray.bounds.width == 180)
        let compactFit = otherTray.picker.convert(NSPoint(x: otherTray.picker.bounds.midX,
                                                               y: otherTray.picker.bounds.midY), to: nil)
        let compactHit = try #require(hosted.hitTest(hosted.superview?.convert(compactFit, from: nil) ?? compactFit))
        #expect(compactHit === otherTray.picker || compactHit.isDescendant(of: otherTray.picker))
    }

    private func drag(_ view: NSView, from start: NSPoint, to end: NSPoint, window: NSWindow) throws {
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: start))
        view.mouseDragged(with: try event(.leftMouseDragged, at: end))
        view.mouseUp(with: try event(.leftMouseUp, at: end))
    }

    private func fixture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 60, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try #require(context.makeImage())
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

@MainActor
private final class ImagePreviewControlTerminal: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct ImagePreviewControlTerminalView: NSViewRepresentable {
    let view: ImagePreviewControlTerminal
    func makeNSView(context: Context) -> ImagePreviewControlTerminal { view }
    func updateNSView(_ view: ImagePreviewControlTerminal, context: Context) {}
}
