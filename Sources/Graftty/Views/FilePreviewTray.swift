import AppKit
import QuickLookUI
import SwiftUI

struct FilePreviewTray: NSViewRepresentable {
    let preview: ImagePreviewStore.Preview
    let onDismiss: () -> Void
    let onInteraction: (ImagePreviewInteraction) -> Void
    func makeNSView(context: Context) -> NativeFilePreviewTray {
        NativeFilePreviewTray(preview: preview, onDismiss: onDismiss, onInteraction: onInteraction)
    }
    static func dismantleNSView(_ view: NativeFilePreviewTray, coordinator: ()) {
        view.tearDown()
    }
    func updateNSView(_ view: NativeFilePreviewTray, context: Context) {
        view.onDismiss = onDismiss
        view.onInteraction = onInteraction
        view.update(preview)
    }
}

/// Quick Look owns file rendering; the tray owns collection navigation and placement.
@MainActor
final class NativeFilePreviewTray: NSVisualEffectView {
    let quickLook: QLPreviewView
    let picker = NSPopUpButton()
    let previous = FilePreviewButton(title: "", target: nil, action: nil)
    let next = FilePreviewButton(title: "", target: nil, action: nil)
    let open = FilePreviewButton(title: "Open…", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let openFile: (URL) async throws -> Void
    private var isOpening = false
    private var isTornDown = false
    private(set) var openErrorMessage: String?
    let close = FilePreviewButton(title: "", target: nil, action: nil)
    let header = ImagePreviewGestureHandle(kind: .move)
    let grip = ImagePreviewGestureHandle(kind: .resize)
    let bottom = ImagePreviewGestureHandle(kind: .resizeHeight)
    var onDismiss: () -> Void
    var onInteraction: (ImagePreviewInteraction) -> Void
    private var preview: ImagePreviewStore.Preview
    private(set) var selectedIndex = 0
    var previewURL: URL { preview.files[selectedIndex].url }
    private weak var priorResponder: NSResponder?

    init(preview: ImagePreviewStore.Preview, onDismiss: @escaping () -> Void,
         onInteraction: @escaping (ImagePreviewInteraction) -> Void,
         openFile: @escaping (URL) async throws -> Void = FilePreviewExternalOpen.open) {
        self.preview = preview
        self.openFile = openFile
        self.onDismiss = onDismiss
        self.onInteraction = onInteraction
        quickLook = QLPreviewView(frame: .zero, style: .normal)
        // SwiftUI owns teardown. A window close must not independently close
        // Quick Look before dismantleNSView, since closing it twice aborts.
        quickLook.shouldCloseWithWindow = false
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        quickLook.autostarts = false
        picker.target = self
        picker.action = #selector(selectFile)
        picker.setAccessibilityLabel("Preview files")
        for (button, symbol, label, action) in [
            (previous, "chevron.left", "Previous preview", #selector(previousFile)),
            (next, "chevron.right", "Next preview", #selector(nextFile)),
            (close, "xmark", "Close preview", #selector(closePreview))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.isBordered = false
            button.target = self
            button.action = action
            button.previewTray = self
        }
        open.target = self
        open.action = #selector(openSelectedFile)
        open.bezelStyle = .rounded
        open.previewTray = self
        open.setAccessibilityLabel("Open original file")
        open.toolTip = "Open the selected original file in its default app"
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.drawsBackground = true
        errorLabel.backgroundColor = .windowBackgroundColor
        errorLabel.isHidden = true
        for view in [quickLook, header, bottom, grip, errorLabel] { addSubview(view) }
        for view in [previous, next, picker, open, close] { header.addSubview(view) }
        for handle in [header, bottom, grip] {
            handle.onInteraction = { [weak self] interaction in
                guard let self else { return }
                if case .began = interaction { self.claimFocus() }
                self.onInteraction(interaction)
            }
        }
        grip.setAccessibilityLabel("Resize preview")
        bottom.setAccessibilityLabel("Resize preview height")
        loadSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        // Keep the snapshot owners alive until Quick Look releases its item.
        withExtendedLifetime(preview) { quickLook.close() }
    }

    func update(_ preview: ImagePreviewStore.Preview) {
        guard !isTornDown, preview.id != self.preview.id else { return }
        self.preview = preview
        selectedIndex = 0
        openErrorMessage = nil
        errorLabel.isHidden = true
        loadSelection()
    }

    private func loadSelection() {
        picker.removeAllItems()
        for (index, file) in preview.files.enumerated() {
            picker.addItem(withTitle: "\(index + 1)/\(preview.files.count)  \(file.url.lastPathComponent)")
        }
        picker.selectItem(at: selectedIndex)
        previous.isEnabled = selectedIndex > 0
        next.isEnabled = selectedIndex + 1 < preview.files.count
        quickLook.previewItem = preview.files[selectedIndex].url as NSURL
    }
    @objc private func openSelectedFile() { Task { await openInDefaultApp() } }
    func openInDefaultApp() async {
        guard !isTornDown, !isOpening else { return }
        isOpening = true
        open.isEnabled = false
        let id = preview.id
        let file = preview.files[selectedIndex]
        openErrorMessage = nil
        errorLabel.isHidden = true
        defer { isOpening = false; open.isEnabled = true }
        do { try await openFile(file.sourceURL ?? file.url) }
        catch {
            guard !isTornDown, id == preview.id, preview.files[selectedIndex].url == file.url else { return }
            openErrorMessage = error.localizedDescription
            errorLabel.stringValue = "Could not open file: " + error.localizedDescription
            errorLabel.setAccessibilityLabel(errorLabel.stringValue)
            errorLabel.isHidden = false
        }
    }
    @objc func previousFile() { select(selectedIndex - 1) }
    @objc func nextFile() { select(selectedIndex + 1) }
    @objc private func selectFile() { select(picker.indexOfSelectedItem) }
    private func select(_ index: Int) {
        guard !isTornDown, preview.files.indices.contains(index) else { return }
        claimFocus()
        selectedIndex = index
        openErrorMessage = nil
        errorLabel.isHidden = true
        loadSelection()
    }
    override func layout() {
        super.layout()
        let compact = bounds.width < 300
        let headerHeight = min(compact ? 72.0 : 44.0, bounds.height)
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        let openWidth = ceil(max(open.intrinsicContentSize.width, open.cell?.cellSize.width ?? 0))
        previous.frame = NSRect(x: 4, y: 10, width: 24, height: 24)
        next.frame = NSRect(x: 30, y: 10, width: 24, height: 24)
        close.frame = NSRect(x: max(0, bounds.width - 30), y: headerHeight - 34, width: 24, height: 24)
        open.frame = NSRect(x: max(58, bounds.width - (compact ? 8 : 38) - openWidth), y: 10, width: openWidth, height: 24)
        picker.frame = NSRect(x: compact ? 8 : 58, y: headerHeight - 36,
                              width: max(0, compact ? bounds.width - 46 : open.frame.minX - 66), height: 28)
        quickLook.frame = NSRect(x: 0, y: 10, width: bounds.width, height: max(0, bounds.height - headerHeight - 10))
        errorLabel.frame = NSRect(x: 8, y: 12, width: max(0, bounds.width - 40), height: 36)
        bottom.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 24), height: 10)
        grip.frame = NSRect(x: max(0, bounds.width - 24), y: 0, width: 24, height: 24)
    }
    var ownsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }
    override var acceptsFirstResponder: Bool { true }
    func claimFocus() {
        if !ownsFocus { priorResponder = window?.firstResponder }
        window?.makeFirstResponder(self)
    }
    @objc func closePreview() {
        guard !isTornDown else { return }
        if ownsFocus { window?.makeFirstResponder(priorResponder) }
        onDismiss()
    }
    override func cancelOperation(_ sender: Any?) { if ownsFocus { closePreview() } }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown, !ownsFocus {
            priorResponder = window?.firstResponder
        }
        return hit
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(self) } else { super.keyDown(with: event) }
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, ownsFocus { window?.makeFirstResponder(priorResponder) }
        super.viewWillMove(toSuperview: newSuperview)
    }
}

@MainActor
final class FilePreviewButton: NSButton {
    weak var previewTray: NativeFilePreviewTray?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        previewTray?.claimFocus()
        super.mouseDown(with: event)
    }
}
