import AppKit
import SwiftUI
import GrafttyKit

struct ImagePreviewOverlay: View {
    let pane: PaneSlotID?
    let preview: ImagePreviewStore.Preview?
    let onDismiss: () -> Void
    var onPopOut: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let pane, let preview {
                PositionedImagePreview(preview: preview, viewport: geometry.size, onDismiss: onDismiss, onPopOut: onPopOut)
                    .id(pane)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct PositionedImagePreview: View {
    let preview: ImagePreviewStore.Preview
    let viewport: CGSize
    let onDismiss: () -> Void
    let onPopOut: (() -> Void)?
    @State private var requestedFrame: CGRect?
    @State private var interactionStart: CGRect?

    private var frame: CGRect {
        requestedFrame.map { ImagePreviewGeometry.constrained($0, in: viewport) }
            ?? ImagePreviewGeometry.initialFrame(in: viewport)
    }

    var body: some View {
        FilePreviewTray(preview: preview, onDismiss: onDismiss, onInteraction: interact, onPopOut: onPopOut)
            .frame(width: frame.width, height: frame.height)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .position(x: frame.midX, y: frame.midY)
    }

    private func interact(_ interaction: ImagePreviewInteraction) {
        switch interaction {
        case .began: interactionStart = frame
        case let .changed(kind, translation):
            guard let start = interactionStart else { return }
            switch kind {
            case .move: requestedFrame = ImagePreviewGeometry.moving(start, by: translation, in: viewport)
            case .resize: requestedFrame = ImagePreviewGeometry.resizing(start, by: translation, in: viewport)
            case .resizeHeight:
                requestedFrame = ImagePreviewGeometry.resizing(start, by: CGSize(width: 0, height: translation.height), in: viewport)
            }
        case .ended: interactionStart = nil
        }
    }
}

@MainActor
final class ImagePreviewGestureHandle: NSView {
    let kind: ImagePreviewInteraction.Kind
    var isEnabled = true
    var onInteraction: (ImagePreviewInteraction) -> Void = { _ in }
    private var startLocation: NSPoint?

    init(kind: ImagePreviewInteraction.Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        guard isEnabled else { return }
        let cursor: NSCursor
        if kind == .move { cursor = .openHand }
        else if kind == .resizeHeight { cursor = .resizeUpDown }
        else if #available(macOS 15, *) { cursor = .frameResize(position: .bottomRight, directions: .all) }
        else { cursor = .crosshair }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        startLocation = event.locationInWindow
        onInteraction(.began(kind))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startLocation else { return }
        onInteraction(.changed(kind, CGSize(width: event.locationInWindow.x - startLocation.x,
                                            height: startLocation.y - event.locationInWindow.y)))
    }
    override func mouseUp(with event: NSEvent) {
        guard startLocation != nil else { return }
        mouseDragged(with: event)
        startLocation = nil
        onInteraction(.ended)
    }
    override func draw(_ dirtyRect: NSRect) {
        if kind == .move {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            return
        }
        if kind == .resizeHeight {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 16, y: bounds.midY - 1,
                                            width: 32, height: 2), xRadius: 1, yRadius: 1).fill()
            return
        }
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        for inset in [5.0, 9, 13] {
            path.move(to: NSPoint(x: bounds.maxX - inset, y: 4))
            path.line(to: NSPoint(x: bounds.maxX - 4, y: inset))
        }
        path.lineWidth = 1
        path.stroke()
    }
}
