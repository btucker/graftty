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

/// AppKit drag source laid over a worktree heading. SwiftUI's `.draggable`
/// never started a session for these rows on the project column, so this
/// overlay owns the left mouse button: a press-and-release selects, and a
/// drag past the threshold begins an `NSDraggingSession` with the move
/// payload. Right-clicks and ctrl-clicks pass through to the menu overlay.
struct WorktreeDragSourceOverlay: NSViewRepresentable {
    let payload: TransferableWorktreeMove
    let onClick: () -> Void

    func makeNSView(context: Context) -> WorktreeDragSourceView {
        let view = WorktreeDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: WorktreeDragSourceView, context: Context) { update(view) }

    private func update(_ view: WorktreeDragSourceView) {
        view.payload = payload
        view.onClick = onClick
    }
}

final class WorktreeDragSourceView: NSView, NSDraggingSource {
    var payload: TransferableWorktreeMove?
    var onClick: (() -> Void)?
    private var press: (event: NSEvent, origin: NSPoint)?

    /// Movement before a press becomes a drag instead of a click.
    static let dragThreshold: CGFloat = 4

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
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
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: press.event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }
        press = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    /// The row as currently drawn, for the drag image.
    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let contentView = window?.contentView else { return image }
        let rect = convert(bounds, to: contentView)
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
