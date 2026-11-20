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
    var onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollbackMapPointerView { ScrollbackMapPointerView(content: content) }

    func updateNSView(_ view: ScrollbackMapPointerView, context: Context) {
        view.content.rootView = content
        view.terminalOnLeft = terminalOnLeft
        view.onHover = onHover
        view.onScrub = onScrub
        view.onDrag = onDrag
        view.onClick = onClick
        view.previewArea = previewArea
    }

    static func dismantleNSView(_ view: ScrollbackMapPointerView, coordinator: ()) {
        view.previewArea = nil
    }
}

final class ScrollbackMapPointerView: NSView {
    let content: NSHostingView<AnyView>
    var terminalOnLeft = true
    var previewArea: CGRect? {
        didSet { if previewArea != oldValue { updatePreviewTracking() } }
    }
    var onHover: ((CGFloat?) -> Void)?
    var onScrub: ((CGFloat?) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onClick: ((CGFloat) -> Void)?
    private var press: NSPoint?
    private var dragged = false
    private var pointerTracking: NSTrackingArea?
    private weak var previewTrackingHost: NSView?
    private var previewTracking: NSTrackingArea?

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
        updatePreviewTracking()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removePreviewTracking()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePreviewTracking()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updatePreviewTracking()
        // AppKit updates this tracking area when the pane resizes.
        guard pointerTracking == nil else { return }
        let tracking = NSTrackingArea(rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func updatePreviewTracking() {
        guard let previewArea, let host = window?.contentView else {
            removePreviewTracking()
            return
        }
        // The previews extend beyond this view. Track them from the window's
        // content view so the gutter remains the only interactive input area.
        let rect = host.convert(previewArea, from: self).intersection(host.bounds)
        guard !rect.isNull, !rect.isEmpty else {
            removePreviewTracking()
            return
        }
        if previewTrackingHost === host, previewTracking?.rect == rect { return }
        removePreviewTracking()
        let tracking = NSTrackingArea(rect: rect, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self)
        host.addTrackingArea(tracking)
        previewTrackingHost = host
        previewTracking = tracking
    }

    private func removePreviewTracking() {
        if let previewTracking { previewTrackingHost?.removeTrackingArea(previewTracking) }
        previewTracking = nil
        previewTrackingHost = nil
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onHover?(point.y)
        } else if previewArea?.contains(point) != true {
            onHover?(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !bounds.contains(point), previewArea?.contains(point) != true { onHover?(nil) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Re-hit-test a point just inside the terminal beside the gutter.
        guard let root = window?.contentView else { return }
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) { onHover?(location.y) }
        let x = terminalOnLeft ? bounds.minX - 1 : bounds.maxX + 1
        let point = convert(NSPoint(x: x, y: location.y), to: root.superview)
        let target = root.hitTest(point)
        if target !== self { target?.scrollWheel(with: event) }
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
        if dragged { onDrag?(point.y) } else { onClick?(point.y) }
        press = nil
        onHover?(bounds.contains(point) || previewArea?.contains(point) == true ? point.y : nil)
        onScrub?(nil)
    }
}
#endif
