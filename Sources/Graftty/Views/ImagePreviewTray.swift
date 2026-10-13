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
                ImagePreviewTray(preview: preview, onDismiss: onDismiss)
                    .id(pane)
                    .frame(height: ImagePreviewLayout.trayHeight(paneHeight: geometry.size.height))
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

struct ImagePreviewTray: NSViewRepresentable {
    let preview: ImagePreviewStore.Preview
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NativeImagePreviewTray {
        NativeImagePreviewTray(preview: preview, onDismiss: onDismiss)
    }

    func updateNSView(_ view: NativeImagePreviewTray, context: Context) {
        view.onDismiss = onDismiss
        view.updatePreview(preview)
    }
}

/// Native chrome and responder-local Escape handling. Arrival never claims focus.
@MainActor
final class NativeImagePreviewTray: NSVisualEffectView {
    let scrollView = PreviewScrollView()
    private let canvas = PreviewImageView()
    private let title = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "Fit")
    private var buttons: [NSButton] = []
    private weak var priorResponder: NSResponder?
    var onDismiss: () -> Void
    private var imageSize: CGSize
    private var previewID: UUID

    init(preview: ImagePreviewStore.Preview, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        previewID = preview.id
        imageSize = CGSize(width: preview.image.width, height: preview.image.height)
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        title.stringValue = preview.filename
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.setAccessibilityLabel("Image preview filename")
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.alignment = .center
        addSubview(title)
        addSubview(zoomLabel)
        buttons = [button("minus.magnifyingglass", label: "Zoom out", action: #selector(zoomOut)),
                   button("plus.magnifyingglass", label: "Zoom in", action: #selector(zoomIn)),
                   button(nil, label: "Fit", action: #selector(fit)),
                   button("xmark", label: "Close image preview", action: #selector(closePreview))]
        for button in buttons { addSubview(button) }
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
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
    }

    func updatePreview(_ preview: ImagePreviewStore.Preview) {
        guard preview.id != previewID else { return }
        previewID = preview.id
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

    private func button(_ symbol: String?, label: String, action: Selector) -> NSButton {
        let button = PreviewButton(title: symbol == nil ? label : "", target: self, action: action)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.previewTray = self
        return button
    }

    override func layout() {
        super.layout()
        let headerHeight = min(36, bounds.height)
        let controlsWidth: CGFloat = 184
        title.frame = NSRect(x: 12, y: bounds.height - headerHeight + 9, width: max(0, bounds.width - controlsWidth - 24), height: 18)
        let start = max(0, bounds.width - controlsWidth)
        zoomLabel.frame = NSRect(x: start, y: bounds.height - headerHeight + 9, width: 44, height: 18)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: start + 46 + CGFloat(index) * 32, y: bounds.height - headerHeight + 5, width: 30, height: 26)
        }
        let newFrame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        if scrollView.frame != newFrame {
            scrollView.frame = newFrame
            // The document's unzoomed size remains the available viewport;
            // NSScrollView applies magnification and panning independently.
            let viewport = scrollView.contentSize
            canvas.frame = NSRect(origin: .zero, size: viewport)
            canvas.fittedSize = ImagePreviewLayout.fit(image: imageSize, viewport: viewport)
        }
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

    override func mouseDown(with event: NSEvent) { claimFocus() }

    override func cancelOperation(_ sender: Any?) {
        // This selector only reaches the tray when its responder chain owns focus.
        if ownsFocus { closePreview() }
    }

    @objc func closePreview() {
        if ownsFocus { window?.makeFirstResponder(priorResponder) }
        onDismiss()
    }

    @objc func fit() {
        scrollView.magnification = 1
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        zoomLabel.stringValue = "Fit"
    }

    @objc func zoomIn() { zoom(by: 1.5) }
    @objc func zoomOut() { zoom(by: 1 / 1.5) }

    func updateZoomLabel() {
        let zoom = scrollView.magnification
        zoomLabel.stringValue = zoom == 1 ? "Fit" : "\(Int(zoom * 100))%"
    }

    private func zoom(by factor: CGFloat) {
        let zoom = ImagePreviewLayout.clampZoom(scrollView.magnification * factor)
        let visible = canvas.visibleRect
        scrollView.setMagnification(zoom, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        updateZoomLabel()
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
