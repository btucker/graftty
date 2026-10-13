import AppKit
import SwiftUI
import GrafttyKit

struct ImagePreviewOverlay: View {
    let pane: PaneSlotID?
    let preview: ImagePreviewStore.Preview?
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let pane, let preview {
                PositionedImagePreview(preview: preview, viewport: geometry.size, onDismiss: onDismiss)
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
    @State private var requestedFrame: CGRect?
    @State private var interactionStart: CGRect?

    private var frame: CGRect {
        requestedFrame.map { ImagePreviewGeometry.constrained($0, in: viewport) }
            ?? ImagePreviewGeometry.initialFrame(in: viewport)
    }

    var body: some View {
        ImagePreviewTray(preview: preview, onDismiss: onDismiss, onInteraction: interact)
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

struct ImagePreviewTray: NSViewRepresentable {
    let preview: ImagePreviewStore.Preview
    let onDismiss: () -> Void
    var onInteraction: (ImagePreviewInteraction) -> Void = { _ in }

    func makeNSView(context: Context) -> NativeImagePreviewTray {
        NativeImagePreviewTray(preview: preview, onDismiss: onDismiss, onInteraction: onInteraction)
    }

    func updateNSView(_ view: NativeImagePreviewTray, context: Context) {
        view.onDismiss = onDismiss
        view.onInteraction = onInteraction
        view.updatePreview(preview)
    }
}

/// Native chrome and responder-local Escape handling. Arrival never claims focus.
@MainActor
final class NativeImagePreviewTray: NSVisualEffectView {
    static let headerHeight: CGFloat = 44
    static let bottomEdgeHeight: CGFloat = 10
    let scrollView = PreviewScrollView()
    let dragHandle = ImagePreviewGestureHandle(kind: .move)
    let resizeGrip = ImagePreviewGestureHandle(kind: .resize)
    let bottomEdge = ImagePreviewGestureHandle(kind: .resizeHeight)
    let zoomControls = PreviewZoomControls(labels: ["", "Fit", ""], trackingMode: .momentary, target: nil, action: nil)
    private let canvas = PreviewImageView()
    private let title = PreviewTitleField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "Fit")
    private let openButton = PreviewButton(title: "Open…", target: nil, action: nil)
    private let closeButton = PreviewButton(title: "", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private weak var priorResponder: NSResponder?
    var onDismiss: () -> Void
    var onInteraction: (ImagePreviewInteraction) -> Void
    private let openFile: (URL) async throws -> Void
    private var sourceURL: URL?
    private var isOpening = false
    private(set) var openErrorMessage: String?
    private var imageSize: CGSize
    private var previewID: UUID

    init(preview: ImagePreviewStore.Preview, onDismiss: @escaping () -> Void,
         onInteraction: @escaping (ImagePreviewInteraction) -> Void = { _ in },
         openFile: @escaping (URL) async throws -> Void = ImagePreviewExternalOpen.open) {
        self.onDismiss = onDismiss
        self.onInteraction = onInteraction
        self.openFile = openFile
        sourceURL = preview.sourceURL
        previewID = preview.id
        imageSize = CGSize(width: preview.image.width, height: preview.image.height)
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        title.stringValue = preview.filename
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.setAccessibilityLabel("Image preview filename")
        title.toolTip = "Drag to move image preview"
        title.dragHandle = dragHandle
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .right
        zoomControls.segmentStyle = .rounded
        zoomControls.controlSize = .regular
        zoomControls.setImage(NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom out"), forSegment: 0)
        zoomControls.setImage(NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom in"), forSegment: 2)
        zoomControls.setWidth(28, forSegment: 0)
        zoomControls.setWidth(44, forSegment: 1)
        zoomControls.setWidth(28, forSegment: 2)
        zoomControls.setToolTip("Zoom out", forSegment: 0)
        zoomControls.setToolTip("Fit image", forSegment: 1)
        zoomControls.setToolTip("Zoom in", forSegment: 2)
        zoomControls.setAccessibilityLabel("Image zoom")
        zoomControls.previewTray = self
        zoomControls.target = self
        zoomControls.action = #selector(changeZoom)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .regular
        openButton.toolTip = "Open original file in Preview.app"
        openButton.setAccessibilityLabel("Open in Preview")
        openButton.target = self
        openButton.action = #selector(openPreviewAction)
        openButton.previewTray = self
        openButton.isEnabled = sourceURL != nil
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close image preview")
        closeButton.isBordered = false
        closeButton.toolTip = "Close image preview"
        closeButton.setAccessibilityLabel("Close image preview")
        closeButton.target = self
        closeButton.action = #selector(closePreview)
        closeButton.previewTray = self
        addSubview(dragHandle)
        for view in [title, zoomLabel, zoomControls, openButton, closeButton] { dragHandle.addSubview(view) }
        dragHandle.onInteraction = { [weak self] interaction in self?.handleInteraction(interaction) }
        resizeGrip.onInteraction = { [weak self] interaction in self?.handleInteraction(interaction) }
        resizeGrip.setAccessibilityLabel("Resize image preview")
        resizeGrip.toolTip = "Drag to resize image preview"
        bottomEdge.onInteraction = { [weak self] interaction in self?.handleInteraction(interaction) }
        bottomEdge.setAccessibilityLabel("Resize image preview height")
        bottomEdge.toolTip = "Drag to resize image preview height"
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 8
        scrollView.previewTray = self
        canvas.image = NSImage(cgImage: preview.image, size: imageSize)
        canvas.imageScaling = .scaleProportionallyUpOrDown
        canvas.previewTray = self
        canvas.setAccessibilityLabel("Image preview")
        scrollView.documentView = canvas
        addSubview(scrollView)
        addSubview(bottomEdge)
        addSubview(resizeGrip)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .labelColor
        errorLabel.drawsBackground = true
        errorLabel.backgroundColor = .windowBackgroundColor
        errorLabel.isHidden = true
        addSubview(errorLabel)
        updateZoomLabel()
    }

    func updatePreview(_ preview: ImagePreviewStore.Preview) {
        guard preview.id != previewID else { return }
        previewID = preview.id
        sourceURL = preview.sourceURL
        openButton.isEnabled = sourceURL != nil && !isOpening
        openErrorMessage = nil
        errorLabel.isHidden = true
        title.stringValue = preview.filename
        imageSize = CGSize(width: preview.image.width, height: preview.image.height)
        canvas.image = NSImage(cgImage: preview.image, size: imageSize)
        canvas.fittedSize = ImagePreviewLayout.fit(image: imageSize, viewport: scrollView.contentSize)
        fit()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, ownsFocus { window?.makeFirstResponder(priorResponder) }
        super.viewWillMove(toSuperview: newSuperview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let compact = bounds.width < 300
        let height = min(compact ? 72 : Self.headerHeight, bounds.height)
        dragHandle.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        let buttonWidth = ceil(max(openButton.intrinsicContentSize.width, openButton.cell?.cellSize.width ?? 0))
        let zoomWidth = ceil(zoomControls.intrinsicContentSize.width)
        let closeX = max(0, bounds.width - 34)
        closeButton.frame = NSRect(x: closeX, y: height - 34, width: 24, height: 24)
        let openX = compact ? bounds.width - 4 - buttonWidth : closeX - 8 - buttonWidth
        openButton.frame = NSRect(x: openX, y: 10, width: buttonWidth, height: 24)
        let zoomX = compact ? 4 : openX - 10 - zoomWidth
        zoomControls.frame = NSRect(x: zoomX, y: 10, width: zoomWidth, height: 24)
        // Hide only the redundant percentage in narrow trays, keeping actions legible.
        zoomLabel.isHidden = compact || zoomX < 170
        zoomLabel.frame = NSRect(x: zoomX - 56, y: 13, width: 46, height: 18)
        title.frame = NSRect(x: 12, y: height - 31,
                             width: max(0, compact ? closeX - 20 : zoomX - (zoomLabel.isHidden ? 24 : 78)), height: 18)
        let newFrame = NSRect(x: 0, y: Self.bottomEdgeHeight, width: bounds.width,
                              height: max(0, bounds.height - height - Self.bottomEdgeHeight))
        if scrollView.frame != newFrame {
            scrollView.frame = newFrame
            let viewport = scrollView.contentSize
            canvas.frame = NSRect(origin: .zero, size: viewport)
            canvas.fittedSize = ImagePreviewLayout.fit(image: imageSize, viewport: viewport)
        }
        resizeGrip.frame = NSRect(x: max(0, bounds.width - 24), y: 0, width: 24, height: 24)
        bottomEdge.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 24), height: Self.bottomEdgeHeight)
        errorLabel.frame = NSRect(x: 12, y: 12, width: max(0, bounds.width - 48), height: 34)
    }

    var ownsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    func claimFocus() {
        if !ownsFocus { priorResponder = window?.firstResponder }
        window?.makeFirstResponder(scrollView)
    }

    private func handleInteraction(_ interaction: ImagePreviewInteraction) {
        if case .began = interaction { claimFocus() }
        onInteraction(interaction)
    }

    override func mouseDown(with event: NSEvent) { claimFocus() }

    override func cancelOperation(_ sender: Any?) {
        if ownsFocus { closePreview() }
    }

    @objc func closePreview() {
        if ownsFocus { window?.makeFirstResponder(priorResponder) }
        onDismiss()
    }

    @objc private func openPreviewAction(_ sender: Any?) {
        Task { await openInPreview() }
    }

    func openInPreview() async {
        guard let sourceURL, !isOpening else { return }
        openErrorMessage = nil
        errorLabel.isHidden = true
        isOpening = true
        openButton.isEnabled = false
        let openingID = previewID
        defer { isOpening = false; openButton.isEnabled = self.sourceURL != nil }
        do {
            try await openFile(sourceURL)
        } catch {
            guard openingID == previewID else { return }
            openErrorMessage = error.localizedDescription
            errorLabel.stringValue = "Could not open in Preview: " + error.localizedDescription
            errorLabel.toolTip = errorLabel.stringValue
            errorLabel.setAccessibilityLabel(errorLabel.stringValue)
            errorLabel.isHidden = false
        }
    }

    @objc private func changeZoom(_ sender: NSSegmentedControl) {
        claimFocus()
        switch sender.selectedSegment {
        case 0: zoomOut()
        case 1: fit()
        case 2: zoomIn()
        default: break
        }
    }

    @objc func fit() {
        scrollView.magnification = 1
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateZoomLabel()
    }

    @objc func zoomIn() { zoom(by: 1.5) }
    @objc func zoomOut() { zoom(by: 1 / 1.5) }

    func updateZoomLabel() {
        let zoom = scrollView.magnification
        zoomLabel.stringValue = zoom == 1 ? "Fit" : "\(Int(zoom * 100))%"
        zoomControls.setEnabled(zoom > 1, forSegment: 0)
        zoomControls.setEnabled(zoom < 8, forSegment: 2)
    }

    private func zoom(by factor: CGFloat) {
        let zoom = ImagePreviewLayout.clampZoom(scrollView.magnification * factor)
        let visible = canvas.visibleRect
        scrollView.setMagnification(zoom, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        updateZoomLabel()
    }
}

@MainActor
final class PreviewZoomControls: NSSegmentedControl {
    weak var previewTray: NativeImagePreviewTray?
    override func mouseDown(with event: NSEvent) {
        previewTray?.claimFocus()
        super.mouseDown(with: event)
    }
}

@MainActor
private final class PreviewTitleField: NSTextField {
    weak var dragHandle: ImagePreviewGestureHandle?
    override func mouseDown(with event: NSEvent) { dragHandle?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { dragHandle?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { dragHandle?.mouseUp(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

@MainActor
final class ImagePreviewGestureHandle: NSView {
    let kind: ImagePreviewInteraction.Kind
    var onInteraction: (ImagePreviewInteraction) -> Void = { _ in }
    private var startLocation: NSPoint?

    init(kind: ImagePreviewInteraction.Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        let cursor: NSCursor
        if kind == .move { cursor = .openHand }
        else if kind == .resizeHeight { cursor = .resizeUpDown }
        else if #available(macOS 15, *) { cursor = .frameResize(position: .bottomRight, directions: .all) }
        else { cursor = .crosshair }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
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

@MainActor
final class PreviewScrollView: NSScrollView {
    weak var previewTray: NativeImagePreviewTray?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        previewTray?.claimFocus()
        super.mouseDown(with: event)
    }
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        previewTray?.updateZoomLabel()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { previewTray?.cancelOperation(self) }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class PreviewImageView: NSImageView {
    weak var previewTray: NativeImagePreviewTray?
    var fittedSize: CGSize = .zero { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) { previewTray?.claimFocus() }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: NSRect(x: (bounds.width - fittedSize.width) / 2,
                              y: (bounds.height - fittedSize.height) / 2,
                              width: fittedSize.width, height: fittedSize.height))
    }
}

@MainActor
private final class PreviewButton: NSButton {
    weak var previewTray: NativeImagePreviewTray?
    override func mouseDown(with event: NSEvent) {
        previewTray?.claimFocus()
        super.mouseDown(with: event)
    }
}
