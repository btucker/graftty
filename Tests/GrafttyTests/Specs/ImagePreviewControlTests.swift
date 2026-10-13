import AppKit
import Foundation
import Testing
import SwiftUI
@testable import Graftty
import GrafttyKit

@MainActor
struct ImagePreviewControlTests {
    @Test("@spec IMAGE-1.14: While the native image tray toolbar is visible, the application shall use native zoom controls, keep Fit legible, and expose Preview through a labeled button or a compact icon without clipping either action.")
    func nativeToolbarDoesNotClipActionLabels() throws {
        _ = NSApplication.shared
        let tray = NativeImagePreviewTray(preview: .init(image: try fixture(), filename: "a long chart filename.png"), onDismiss: {})
        for width in [180.0, 240, 320, 480, 800] {
            tray.frame = NSRect(x: 0, y: 0, width: width, height: 240)
            tray.layoutSubtreeIfNeeded()
            let buttons = descendants(tray).compactMap { $0 as? NSButton }
            let zoom = try #require(descendants(tray).compactMap { $0 as? NSSegmentedControl }.first)
            #expect(zoom.label(forSegment: 1) == "Fit")
            #expect(zoom.width(forSegment: 1) >= 34)
            let preview = try #require(buttons.first { $0.accessibilityLabel() == "Open in Preview" })
            #expect(preview.frame.width >= preview.intrinsicContentSize.width)
            #expect(width < 300 ? preview.image != nil : preview.title == "Preview")
            let close = try #require(buttons.first { $0.accessibilityLabel() == "Close image preview" })
            #expect(preview.frame.maxX <= width)
            #expect(close.frame.maxX <= width)
            #expect(zoom.frame.minX >= 0 && zoom.frame.maxX <= width)
            #expect(preview.frame.minX >= zoom.frame.maxX)
        }
    }

    @Test("@spec IMAGE-1.15: When the user selects Open in Preview from an image tray, the application shall open the originating file specifically in Preview.app and report missing-file, unavailable-app, or launch errors without dismissing the tray.")
    func previewActionOpensOriginatingFileAndReportsErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root)
        var requestedBundle: String?
        let application = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let request = try ImagePreviewExternalOpen.request(file: root) { bundle in
            requestedBundle = bundle
            return application
        }
        #expect(requestedBundle == "com.apple.Preview")
        #expect(request.file == root)
        #expect(request.application == application)
        let link = root.appendingPathExtension("link")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(try ImagePreviewExternalOpen.request(file: link) { _ in application }.file == link)
        let brokenLink = root.appendingPathExtension("broken-link")
        defer { try? FileManager.default.removeItem(at: brokenLink) }
        try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: root.appendingPathExtension("missing"))
        #expect(throws: (any Error).self) { try ImagePreviewExternalOpen.request(file: brokenLink) { _ in application } }
        #expect(throws: (any Error).self) { try ImagePreviewExternalOpen.request(file: root) { _ in nil } }
        let missing = root.appendingPathExtension("missing")
        #expect(throws: (any Error).self) { try ImagePreviewExternalOpen.request(file: missing) { _ in application } }
        var opened: [URL] = [], dismissed = 0, shouldFail = true
        let tray = NativeImagePreviewTray(preview: .init(image: try fixture(), filename: "chart.png", sourceURL: root),
                                          onDismiss: { dismissed += 1 }, openFile: { url in
            opened.append(url)
            if shouldFail { throw CocoaError(.fileReadNoSuchFile) }
        })
        await tray.openInPreview()
        #expect(opened == [root])
        #expect(tray.openErrorMessage != nil)
        let errorField = try #require(descendants(tray).compactMap { $0 as? NSTextField }.first {
            $0.stringValue.hasPrefix("Could not open in Preview:")
        })
        #expect(!errorField.isHidden)
        #expect(dismissed == 0)
        shouldFail = false
        await tray.openInPreview()
        #expect(tray.openErrorMessage == nil)
        #expect(errorField.isHidden)
        let second = root.deletingLastPathComponent().appendingPathComponent("second.png")
        tray.updatePreview(.init(image: try fixture(), filename: "second.png", sourceURL: second))
        await tray.openInPreview()
        #expect(opened == [root, root, second])
    }

    @Test("@spec IMAGE-1.16: When the user drags the image tray header or resize grip, the application shall move or resize the tray within the terminal content bounds while retaining usable controls and an unobscured terminal region, without resizing the terminal grid.")
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
        let preview = ImagePreviewStore.Preview(image: try fixture(), filename: "drag me.png")
        func root(pane: PaneSlotID, preview: ImagePreviewStore.Preview?) -> some View {
            ImagePreviewControlTerminalView(view: terminal).overlay(alignment: .top) {
                ImagePreviewOverlay(pane: pane, preview: preview, onDismiss: {})
            }
        }
        let hosted = NSHostingView(rootView: root(pane: pane, preview: preview))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        let tray = try #require(descendants(hosted).compactMap { $0 as? NativeImagePreviewTray }.first)
        let resizePoint = tray.resizeGrip.convert(NSPoint(x: 12, y: 12), to: nil)
        let grip = try #require(hosted.hitTest(hosted.superview?.convert(resizePoint, from: nil) ?? resizePoint))
        #expect(grip === tray.resizeGrip)
        try drag(grip, from: resizePoint, to: NSPoint(x: resizePoint.x - 200, y: resizePoint.y - 60), window: window)
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        #expect(tray.bounds.size == CGSize(width: 600, height: 330))
        let headerPoint = tray.dragHandle.convert(NSPoint(x: 40, y: 22), to: nil)
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
        let zoomPoint = tray.zoomControls.convert(NSPoint(x: tray.zoomControls.bounds.midX, y: tray.zoomControls.bounds.midY), to: nil)
        let zoomHit = try #require(hosted.hitTest(hosted.superview?.convert(zoomPoint, from: nil) ?? zoomPoint))
        #expect(zoomHit === tray.zoomControls || zoomHit.isDescendant(of: tray.zoomControls))

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
        #expect(descendants(hosted).compactMap { $0 as? NativeImagePreviewTray }.isEmpty)
        hosted.rootView = root(pane: otherPane, preview: .init(image: try fixture(), filename: "other worktree.png"))
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        let otherTray = try #require(descendants(hosted).compactMap { $0 as? NativeImagePreviewTray }.first)
        #expect(otherTray !== tray)
        #expect(hosted.convert(otherTray.bounds, from: otherTray).origin == .zero)
        #expect(otherTray.bounds.width == 360)
        window.setContentSize(CGSize(width: 180, height: 260))
        try await Task.sleep(for: .milliseconds(20))
        hosted.layoutSubtreeIfNeeded()
        #expect(otherTray.bounds.width == 180)
        let compactFit = otherTray.zoomControls.convert(NSPoint(x: otherTray.zoomControls.bounds.midX,
                                                               y: otherTray.zoomControls.bounds.midY), to: nil)
        let compactHit = try #require(hosted.hitTest(hosted.superview?.convert(compactFit, from: nil) ?? compactFit))
        #expect(compactHit === otherTray.zoomControls || compactHit.isDescendant(of: otherTray.zoomControls))
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
