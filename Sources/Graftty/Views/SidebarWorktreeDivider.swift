import AppKit
import SwiftUI

/// A one-point native separator inside a wider drag target.
struct SidebarWorktreeDivider: NSViewRepresentable {
    var onResize: (CGFloat) -> Void
    var onResizeEnd: () -> Void

    func makeNSView(context: Context) -> SidebarWorktreeResizeView {
        let view = SidebarWorktreeResizeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SidebarWorktreeResizeView, context: Context) {
        view.onResize = onResize
        view.onResizeEnd = onResizeEnd
    }
}

final class SidebarWorktreeResizeView: NSView {
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    private var startY: CGFloat?
    private let separator = SidebarSeparatorBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        separator.setAccessibilityIdentifier("Worktree list divider")
        addSubview(separator)
        setAccessibilityIdentifier("Resize pinned agents")
        setAccessibilityLabel("Resize pinned agents")
        toolTip = "Drag to resize pinned agents"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: floor(bounds.midY), width: bounds.width, height: 1)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) { startY = event.locationInWindow.y }

    override func mouseDragged(with event: NSEvent) {
        guard let startY else { return }
        onResize?(startY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        startY = nil
        onResizeEnd?()
    }
}

/// NSBox adds two points above and below its separator alignment rect.
/// Keep the native bounds inside the one-point separator allocation.
private final class SidebarSeparatorBox: NSBox {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}
