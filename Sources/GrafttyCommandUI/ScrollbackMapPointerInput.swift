#if os(macOS)
import AppKit
import SwiftUI

/// A native input plane handles AppKit events inside the map gutter.
struct ScrollbackMapPointerInput: NSViewRepresentable {
    var content: AnyView
    var terminalOnLeft: Bool
    var previewArea: CGRect?
    var onHover: (CGFloat?) -> Void
    var onScrub: (CGFloat?) -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnd: (CGFloat) -> Void
    var onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollbackMapPointerView { ScrollbackMapPointerView(content: content) }

    func updateNSView(_ view: ScrollbackMapPointerView, context: Context) {
        view.content.rootView = content
        view.terminalOnLeft = terminalOnLeft
        view.onHover = onHover
        view.onScrub = onScrub
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onClick = onClick
        view.previewArea = previewArea
    }

    static func dismantleNSView(_ view: ScrollbackMapPointerView, coordinator: ()) {
        view.removePointerTracking()
    }
}

final class ScrollbackMapPointerView: NSView {
    let content: NSHostingView<AnyView>
    var terminalOnLeft = true
    var previewArea: CGRect?
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
        }
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) { setHover(location.y) }
        forwardWheel(event, acrossLeftEdge: terminalOnLeft)
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

/// The button's native input view forwards wheel events into the terminal next to the card.
struct ScrollbackPreviewButtonInput: NSViewRepresentable {
    let railOnRight: Bool
    let select: () -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.railOnRight = railOnRight
        view.select = select
    }

    final class InputView: NSView {
        var railOnRight = true
        var select: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { select?() }
        }
        override func scrollWheel(with event: NSEvent) {
            forwardWheel(event, acrossLeftEdge: !railOnRight)
        }
    }
}

private extension NSView {
    /// Both the gutter and the cards border a gap over the same terminal.
    func forwardWheel(_ event: NSEvent, acrossLeftEdge: Bool) {
        guard let root = window?.contentView else { return }
        let y = min(bounds.maxY - 1, max(bounds.minY + 1, convert(event.locationInWindow, from: nil).y))
        let point = convert(NSPoint(x: acrossLeftEdge ? bounds.minX - 1 : bounds.maxX + 1, y: y), to: root.superview)
        let target = root.hitTest(point)
        if target !== self { target?.scrollWheel(with: event) }
    }
}
#endif
