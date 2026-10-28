#if os(macOS)
import AppKit
import SwiftUI

/// A native input plane keeps the map above the represented terminal in AppKit's
/// hit testing. SwiftUI-only gestures can pass through to that terminal view.
struct ScrollbackMapPointerInput: NSViewRepresentable {
    var content: AnyView
    var onHover: (CGFloat?) -> Void
    var onScrub: (CGFloat?) -> Void
    var onDrag: (CGFloat) -> Void
    var onClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollbackMapPointerView { ScrollbackMapPointerView(content: content) }

    func updateNSView(_ view: ScrollbackMapPointerView, context: Context) {
        view.content.rootView = content
        view.onHover = onHover
        view.onScrub = onScrub
        view.onDrag = onDrag
        view.onClick = onClick
    }
}

final class ScrollbackMapPointerView: NSView {
    let content: NSHostingView<AnyView>
    var onHover: ((CGFloat?) -> Void)?
    var onScrub: ((CGFloat?) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onClick: ((CGFloat) -> Void)?
    private var press: NSPoint?
    private var dragged = false
    private var pointerTracking: NSTrackingArea?

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
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil).y) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

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
        onScrub?(nil)
    }
}
#endif
