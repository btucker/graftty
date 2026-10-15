import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pasteboard payload for an AppKit-initiated worktree drag. The data is
/// the JSON that `TransferableWorktreeMove`'s `CodableRepresentation`
/// produces, so the row drop destination decodes it unchanged.
final class WorktreeDragPasteboardWriter: NSObject, NSPasteboardWriting {
    static let pasteboardType = NSPasteboard.PasteboardType(TransferableWorktreeMove.contentType.identifier)
    let data: Data

    init?(_ payload: TransferableWorktreeMove) {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        self.data = data
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { [Self.pasteboardType] }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.pasteboardType ? data : nil
    }
}

/// AppKit selection and drag source laid over a worktree block. SwiftUI's `.draggable`
/// never started a session for these rows on the project column, so this
/// overlay owns the left mouse button: a press-and-release selects, and a
/// drag past the threshold begins an `NSDraggingSession` with the move
/// payload. Right-clicks and ctrl-clicks pass through to the menu overlay.
/// Independently clickable controls pass through within `excludedRects`.
/// A nil payload preserves selection while disabling worktree drags.
/// Its bounds cover the whole worktree block and form the drag image.
struct WorktreeDragSourceOverlay: NSViewRepresentable {
    let payload: TransferableWorktreeMove?
    var excludedRects: [CGRect] = []
    let onClick: () -> Void

    func makeNSView(context: Context) -> WorktreeDragSourceView {
        let view = WorktreeDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: WorktreeDragSourceView, context: Context) { update(view) }

    private func update(_ view: WorktreeDragSourceView) {
        view.payload = payload
        view.excludedRects = excludedRects
        view.onClick = onClick
    }
}

final class WorktreeDragSourceView: NSView, NSDraggingSource {
    var payload: TransferableWorktreeMove?
    /// Controls that must receive their own clicks, in this view's coordinates.
    var excludedRects: [CGRect] = []
    var onClick: (() -> Void)?
    private var press: (event: NSEvent, origin: NSPoint)?

    /// Movement before a press becomes a drag instead of a click.
    static let dragThreshold: CGFloat = 4

    /// Top-left origin, matching the SwiftUI control anchors.
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The event AppKit is dispatching. Tests point this at a synthesized
    /// press for the duration of a root hit test, because `NSApp.currentEvent`
    /// is only set by the application event loop.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTest(point, event: currentEvent())
    }

    func hitTest(_ point: NSPoint, event: NSEvent?) -> NSView? {
        guard let event, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
        let localPoint = convert(point, from: superview)
        guard !excludedRects.contains(where: { $0.contains(localPoint) }) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        press = (event, convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, let payload, let writer = WorktreeDragPasteboardWriter(payload) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.origin.x, point.y - press.origin.y) >= Self.dragThreshold else { return }
        self.press = nil
        let lifted = bounds
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(lifted, contents: snapshot(of: lifted))
        beginDraggingSession(with: [item], event: press.event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
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

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
