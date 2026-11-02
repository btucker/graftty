#if os(macOS)
import AppKit
import SwiftUI

/// Shared native click and drag handling for sidebar rows.
open class SidebarRowDragSourceView: NSView, NSDraggingSource {
    public var pasteboardWriter: (any NSPasteboardWriting)?
    /// Controls that must receive their own clicks, in this view's coordinates.
    public var excludedRects: [CGRect] = []
    public var onClick: (() -> Void)?
    private var press: (event: NSEvent, origin: NSPoint)?

    /// Movement before a press becomes a drag instead of a click.
    public static let dragThreshold: CGFloat = 4

    /// Top-left origin, matching the SwiftUI control anchors.
    public override var isFlipped: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The event AppKit is dispatching. Tests point this at a synthesized
    /// press for the duration of a root hit test, because `NSApp.currentEvent`
    /// is only set by the application event loop.
    public var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        hitTest(point, event: currentEvent())
    }

    public func hitTest(_ point: NSPoint, event: NSEvent?) -> NSView? {
        guard let event, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
        let localPoint = convert(point, from: superview)
        guard !excludedRects.contains(where: { $0.contains(localPoint) }) else { return nil }
        return super.hitTest(point)
    }

    public override func mouseDown(with event: NSEvent) {
        press = (event, convert(event.locationInWindow, from: nil))
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let press, let writer = pasteboardWriter else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.origin.x, point.y - press.origin.y) >= Self.dragThreshold else { return }
        self.press = nil
        let lifted = bounds
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(lifted, contents: snapshot(of: lifted))
        beginDraggingSession(with: [item], event: press.event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }
        press = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    /// The block as currently drawn, for the drag image.
    private func snapshot(of localRect: CGRect) -> NSImage {
        let image = NSImage(size: localRect.size)
        guard let contentView = window?.contentView else { return image }
        let rect = convert(localRect, to: contentView)
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: rect) else { return image }
        contentView.cacheDisplay(in: rect, to: rep)
        image.addRepresentation(rep)
        return image
    }

    // MARK: NSDraggingSource

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    public func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

#endif
