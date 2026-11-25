#if os(macOS)
import AppKit
import SwiftUI

/// A native input plane handles AppKit events inside the map gutter.
struct ScrollbackMapPointerInput: NSViewRepresentable {
    var content: AnyView
    var previewArea: CGRect?
    var previewRows: [String: CGRect] = [:]
    var onHover: (CGFloat?) -> Void
    var onHoverRow: (String) -> Void = { _ in }
    var onWheel: (CGFloat, Bool) -> Void = { _, _ in }
    var onScrub: (CGFloat?) -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnd: (CGFloat) -> Void
    var onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollbackMapPointerView { ScrollbackMapPointerView(content: content) }

    func updateNSView(_ view: ScrollbackMapPointerView, context: Context) {
        view.content.rootView = content
        view.onHover = onHover
        view.onScrub = onScrub
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onClick = onClick
        view.previewArea = previewArea
        view.previewRows = previewRows
        view.onHoverRow = onHoverRow
        view.onWheel = onWheel
    }

    static func dismantleNSView(_ view: ScrollbackMapPointerView, coordinator: ()) {
        view.removePointerTracking()
    }
}

final class ScrollbackMapPointerView: NSView {
    let content: NSHostingView<AnyView>
    var previewArea: CGRect?
    var previewRows: [String: CGRect] = [:]
    var onHoverRow: ((String) -> Void)?
    var onWheel: ((CGFloat, Bool) -> Void)?
    var onHover: ((CGFloat?) -> Void)?
    var onScrub: ((CGFloat?) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?
    var onClick: ((CGFloat) -> Void)?
    private var press: NSPoint?
    private var dragged = false
    private var hoverY: CGFloat?
    private weak var trackingHost: NSView?
    private var trackingArea: NSTrackingArea?

    init(content: AnyView) {
        self.content = NSHostingView(rootView: content)
        super.init(frame: .zero)
        clipsToBounds = false
        self.content.clipsToBounds = false
        addSubview(self.content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        content.frame = bounds
        installPointerTracking()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removePointerTracking()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installPointerTracking()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func installPointerTracking() {
        guard let host = window?.contentView else { return }
        if trackingHost === host, let trackingArea,
           host.trackingAreas.contains(where: { $0 === trackingArea }) { return }
        removePointerTracking()

        // The gutter is an overlay, and its native visible rect can be clipped
        // by the terminal. The window already covers both the idle gutter and
        // any cards that extend into the terminal.
        let area = NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        host.addTrackingArea(area)
        trackingHost = host
        trackingArea = area
    }

    fileprivate func removePointerTracking() {
        if let trackingArea { trackingHost?.removeTrackingArea(trackingArea) }
        trackingArea = nil
        trackingHost = nil
    }

    private func setHover(_ y: CGFloat?) {
        guard hoverY != y else { return }
        hoverY = y
        onHover?(y)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHiddenOrHasHiddenAncestor {
            setHover(nil)
        } else if bounds.contains(point) {
            setHover(point.y)
        } else if previewArea?.contains(point) != true {
            setHover(nil)
        } else if let row = ScrollbackPreviewRows.row(at: point, in: previewRows) {
            // Over a message inside a card: magnify that one.
            onHoverRow?(row)
        }
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) { setHover(location.y) }
        // The wheel steps the focused message; the terminal stays put (CONTEXT-57.18).
        onWheel?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        press = point
        dragged = false
        onScrub?(point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        onScrub?(point.y)
        dragged = dragged || abs(point.x - press.x) >= 2 || abs(point.y - press.y) >= 2
        if dragged { onDrag?(point.y) }
    }

    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if dragged { onDragEnd?(point.y) } else { onClick?(point.y) }
        press = nil
        setHover(bounds.contains(point) || previewArea?.contains(point) == true ? point.y : nil)
        onScrub?(nil)
    }
}

/// The button's native input view passes wheel travel to the rail (CONTEXT-57.18).
struct ScrollbackPreviewButtonInput: NSViewRepresentable {
    let wheel: (CGFloat, Bool) -> Void
    let select: () -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.wheel = wheel
        view.select = select
    }

    final class InputView: NSView {
        var wheel: ((CGFloat, Bool) -> Void)?
        var select: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { select?() }
        }
        override func scrollWheel(with event: NSEvent) {
            wheel?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
        }
    }
}
#endif
