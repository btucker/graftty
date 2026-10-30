import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GrafttyCommandUI

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

final class WorktreeDragSourceView: SidebarRowDragSourceView {
    var payload: TransferableWorktreeMove? {
        didSet { pasteboardWriter = payload.flatMap(WorktreeDragPasteboardWriter.init) }
    }
}
