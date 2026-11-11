import AppKit
import QuickLookUI
import SwiftUI
import GrafttyProtocol

struct FilePreviewTray: NSViewRepresentable {
    let preview: ImagePreviewStore.Preview
    let onDismiss: () -> Void
    let onInteraction: (ImagePreviewInteraction) -> Void
    var isWindowed = false
    var onPopOut: (() -> Void)? = nil
    var theme: GhosttyTheme = .fallback
    var navigation: FilePreviewNavigation? = nil
    func makeNSView(context: Context) -> NativeFilePreviewTray {
        NativeFilePreviewTray(preview: preview, onDismiss: onDismiss, onInteraction: onInteraction,
                              isWindowed: isWindowed, onPopOut: onPopOut, theme: theme, navigation: navigation)
    }
    static func dismantleNSView(_ view: NativeFilePreviewTray, coordinator: ()) {
        view.tearDown()
    }
    func updateNSView(_ view: NativeFilePreviewTray, context: Context) {
        view.onDismiss = onDismiss
        view.onInteraction = onInteraction
        view.onPopOut = onPopOut
        view.update(preview)
        view.configure(theme: theme, navigation: navigation)
    }
}

/// Quick Look owns file rendering; the tray owns collection navigation and placement.
@MainActor
final class NativeFilePreviewTray: NSView {
    let quickLook: QLPreviewView
    let picker = NSPopUpButton()
    let worktreePicker = NSPopUpButton()
    let filenameLabel = PreviewDragLabel(labelWithString: "")
    let worktreeLabel = PreviewDragLabel(labelWithString: "")
    let separatorLabel = PreviewDragLabel(labelWithString: "/")
    let countLabel = PreviewDragLabel(labelWithString: "")
    let showInTerminal = FilePreviewButton(title: "Show in Terminal", target: nil, action: nil)
    private var navigation: FilePreviewNavigation?
    private var theme: GhosttyTheme
    private var appearanceObservation: NSKeyValueObservation?
    let previous = FilePreviewButton(title: "", target: nil, action: nil)
    let next = FilePreviewButton(title: "", target: nil, action: nil)
    let open = FilePreviewButton(title: "Open…", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let openFile: (URL) async throws -> Void
    private var isOpening = false
    private var isTornDown = false
    private var preferredPickerWidth: CGFloat = 0
    private(set) var openErrorMessage: String?
    let close = FilePreviewButton(title: "", target: nil, action: nil)
    let popOut = FilePreviewButton(title: "", target: nil, action: nil)
    var onPopOut: (() -> Void)? {
        didSet { popOut.isHidden = onPopOut == nil || isWindowed; needsLayout = true }
    }
    private let isWindowed: Bool
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
         openFile: @escaping (URL) async throws -> Void = FilePreviewExternalOpen.open,
         isWindowed: Bool = false, onPopOut: (() -> Void)? = nil,
         theme: GhosttyTheme = .fallback, navigation: FilePreviewNavigation? = nil) {
        self.preview = preview
        self.theme = theme
        self.navigation = navigation
        self.openFile = openFile
        self.onDismiss = onDismiss
        self.onInteraction = onInteraction
        self.isWindowed = isWindowed
        self.onPopOut = onPopOut
        quickLook = QLPreviewView(frame: .zero, style: .normal)
        // SwiftUI owns teardown. A window close must not independently close
        // Quick Look before dismantleNSView, since closing it twice aborts.
        quickLook.shouldCloseWithWindow = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = isWindowed ? 0 : 10
        layer?.masksToBounds = true
        quickLook.autostarts = false
        // Theme only our chrome. HTML and other reviewed documents follow the
        // system appearance, even when Ghostty uses the opposite color scheme.
        quickLook.appearance = NSApp.effectiveAppearance
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTornDown else { return }
                self.quickLook.appearance = NSApp.effectiveAppearance
            }
        }
        picker.target = self
        picker.action = #selector(selectFile(_:))
        picker.setAccessibilityLabel("Preview files and history")
        for popup in [picker, worktreePicker] {
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 12)
            (popup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        worktreePicker.target = self
        worktreePicker.action = #selector(selectWorktree)
        worktreePicker.setAccessibilityLabel("Preview worktree")
        for label in [filenameLabel, worktreeLabel, separatorLabel, countLabel] {
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
        }
        countLabel.alignment = .center
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        showInTerminal.target = self
        showInTerminal.action = #selector(returnToTerminal)
        showInTerminal.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Show in Terminal")
        showInTerminal.imagePosition = .imageLeading
        showInTerminal.setAccessibilityLabel("Show in Terminal")
        showInTerminal.toolTip = "Show this preview in its terminal"
        showInTerminal.previewTray = self
        showInTerminal.isBordered = false
        for (button, symbol, label, action) in [
            (previous, "chevron.left", "Previous file", #selector(previousFile)),
            (next, "chevron.right", "Next file", #selector(nextFile)),
            (close, "xmark", "Close preview", #selector(closePreview)),
            (popOut, "arrow.up.right.square", "Open preview in window", #selector(popOutPreview))
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
        open.isBordered = false
        open.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        open.imagePosition = .imageLeading
        open.previewTray = self
        open.setAccessibilityLabel("Open original file")
        open.toolTip = "Open the selected original file in its default app"
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.drawsBackground = true
        errorLabel.backgroundColor = .windowBackgroundColor
        errorLabel.isHidden = true
        for view in [quickLook, header, bottom, grip, errorLabel] { addSubview(view) }
        for view in [previous, next, picker, open, close, popOut, worktreePicker, filenameLabel, worktreeLabel, separatorLabel, countLabel, showInTerminal] { header.addSubview(view) }
        popOut.isHidden = onPopOut == nil || isWindowed
        close.isHidden = isWindowed
        bottom.isHidden = isWindowed
        grip.isHidden = isWindowed
        header.movesWindow = isWindowed
        for handle in [header, bottom, grip] {
            handle.onInteraction = { [weak self] interaction in
                guard let self else { return }
                if case .began = interaction { self.claimFocus() }
                self.onInteraction(interaction)
            }
        }
        grip.setAccessibilityLabel("Resize preview")
        bottom.setAccessibilityLabel("Resize preview height")
        configure(theme: theme, navigation: navigation)
        loadSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        appearanceObservation = nil
        // Keep the snapshot owners alive until Quick Look releases its item.
        withExtendedLifetime(preview) { quickLook.close() }
    }

    func update(_ preview: ImagePreviewStore.Preview) {
        guard !isTornDown else { return }
        let isRevision = preview.id == self.preview.id
        guard !isRevision || preview.files.map(\.url) != self.preview.files.map(\.url) else { return }
        // Quick Look may still be reading the old snapshot until it gets the new item.
        withExtendedLifetime(self.preview) {
            self.preview = preview
            if !isRevision || !preview.files.indices.contains(selectedIndex) {
                selectedIndex = 0
                openErrorMessage = nil
                errorLabel.isHidden = true
            }
            loadSelection()
        }
    }

    func configure(theme: GhosttyTheme, navigation: FilePreviewNavigation?) {
        guard !isTornDown else { return }
        self.theme = theme
        self.navigation = navigation
        appearance = theme.nsAppearance
        layer?.backgroundColor = theme.backgroundNSColor.cgColor
        let foreground = NSColor(theme.foreground)
        let secondary = foreground.withAlphaComponent(theme.isDark ? 0.65 : 0.9)
        for handle in [header, bottom, grip] {
            handle.backgroundColor = NSColor(theme.core.contextBackground)
            handle.foregroundColor = secondary
            handle.separatorColor = NSColor(theme.core.contextSeparator)
            handle.needsDisplay = true
        }
        for label in [filenameLabel, worktreeLabel, separatorLabel, countLabel] {
            label.textColor = label === filenameLabel ? foreground : secondary
        }
        for button in [previous, next, open, close, popOut, showInTerminal] {
            button.contentTintColor = foreground
            button.font = .systemFont(ofSize: 12)
        }
        for popup in [picker, worktreePicker] { popup.contentTintColor = foreground }
        errorLabel.backgroundColor = NSColor(theme.core.contextBackground)
        errorLabel.textColor = foreground
        rebuildMenus()
    }

    private func loadSelection() {
        previous.isEnabled = selectedIndex > 0
        next.isEnabled = selectedIndex + 1 < preview.files.count
        quickLook.previewItem = preview.files[selectedIndex].url as NSURL
        let file = preview.files[selectedIndex]
        if let app = NSWorkspace.shared.urlForApplication(toOpen: file.sourceURL ?? file.url) {
            let name = FileManager.default.displayName(atPath: app.path)
            open.title = "Open in " + (name as NSString).deletingPathExtension
        } else { open.title = "Open" }
        rebuildMenus()
    }

    private func rebuildMenus() {
        picker.removeAllItems()
        let older = navigation?.choices.first.map { $0.id != preview.id } ?? false
        let name = preview.files[selectedIndex].url.lastPathComponent
        let title = older ? WorktreePreviewCollection.menuTitle(name, createdAt: preview.createdAt) : name
        filenameLabel.stringValue = title
        filenameLabel.toolTip = title
        for (index, file) in preview.files.enumerated() {
            // addItem(withTitle:) coalesces identical titles. A collection can
            // contain distinct files with the same basename.
            let item = NSMenuItem(title: index == selectedIndex ? title : file.url.lastPathComponent,
                                  action: #selector(selectFile(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            picker.menu?.addItem(item)
        }
        picker.selectItem(at: selectedIndex)
        picker.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor(theme.foreground), .font: NSFont.systemFont(ofSize: 12)
        ])
        let choices = navigation?.choices.filter { $0.id != preview.id } ?? []
        if !choices.isEmpty {
            picker.menu?.addItem(.separator())
            let heading = NSMenuItem(title: "Preview history", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            picker.menu?.addItem(heading)
            for choice in choices {
                let item = NSMenuItem(title: choice.title, action: #selector(selectHistory(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice
                picker.menu?.addItem(item)
            }
        }
        // AppKit sizes the attributed title from the selected item only. Keep
        // its native arrow/padding, but allow every menu title to contribute.
        let textAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let widestTitle = picker.itemArray.map { ($0.title as NSString).size(withAttributes: textAttributes).width }.max() ?? 0
        let chromeWidth = max(0, picker.intrinsicContentSize.width - picker.attributedTitle.size().width)
        preferredPickerWidth = ceil(widestTitle + chromeWidth)
        picker.isHidden = preview.files.count == 1 && choices.isEmpty
        filenameLabel.isHidden = !picker.isHidden
        previous.isHidden = preview.files.count == 1
        next.isHidden = previous.isHidden
        countLabel.isHidden = previous.isHidden
        countLabel.stringValue = "\(selectedIndex + 1) of \(preview.files.count)"
        worktreePicker.removeAllItems()
        if let navigation {
            worktreeLabel.stringValue = URL(fileURLWithPath: navigation.worktreePath).lastPathComponent
            worktreeLabel.toolTip = navigation.worktreePath
            for path in navigation.worktreePaths {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let duplicate = navigation.worktreePaths.filter { URL(fileURLWithPath: $0).lastPathComponent == name }.count > 1
                worktreePicker.addItem(withTitle: duplicate ? path : name)
                worktreePicker.lastItem?.representedObject = path
                worktreePicker.lastItem?.toolTip = path
            }
            if let index = navigation.worktreePaths.firstIndex(of: navigation.worktreePath) { worktreePicker.selectItem(at: index) }
        }
        if let title = worktreePicker.titleOfSelectedItem {
            worktreePicker.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor(theme.foreground).withAlphaComponent(theme.isDark ? 0.65 : 0.9),
                .font: NSFont.systemFont(ofSize: 12)
            ])
        }
        showInTerminal.isHidden = !isWindowed || navigation == nil
        showInTerminal.isEnabled = navigation?.canShowInTerminal == true
        needsLayout = true
    }

    @objc private func selectHistory(_ item: NSMenuItem) {
        guard !isTornDown, let choice = item.representedObject as? FilePreviewNavigation.Choice else { return }
        claimFocus()
        switch choice {
        case .session(let entry): navigation?.onSelectEntry(entry)
        case .stored(let collection): navigation?.onOpenCollection(collection)
        }
    }
    @objc private func selectWorktree() {
        guard let path = worktreePicker.selectedItem?.representedObject as? String else { return }
        // This menu raises another window; it does not retarget this window.
        if let navigation, let current = navigation.worktreePaths.firstIndex(of: navigation.worktreePath) {
            worktreePicker.selectItem(at: current)
        }
        navigation?.onSelectWorktree(path)
    }
    @objc private func returnToTerminal() { navigation?.onShowInTerminal() }
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
    @objc private func popOutPreview() { if !isTornDown { onPopOut?() } }
    @objc private func selectFile(_ sender: Any?) {
        guard let item = (sender as? NSMenuItem) ?? picker.selectedItem else { return }
        if item.representedObject is FilePreviewNavigation.Choice { selectHistory(item) }
        else { select(item.tag) }
    }
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
        let width = bounds.width
        let narrow = width < 300
        let twoRows = narrow && preview.files.count > 1
        let headerHeight = min(twoRows ? 64.0 : (isWindowed ? 40.0 : 36.0), bounds.height)
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: width, height: headerHeight)
        let y = max(0, headerHeight - 30)
        var right = width - 6
        func place(_ control: NSView, width: CGFloat, y: CGFloat) {
            control.frame = NSRect(x: max(0, right - width), y: y, width: width, height: 24)
            right = max(0, right - width - 4)
        }
        for button in [close, popOut] where !button.isHidden { place(button, width: 24, y: y) }
        let iconsOnly = width < 720
        for button in [open, showInTerminal] {
            button.imagePosition = iconsOnly ? .imageOnly : .imageLeading
            if !button.isHidden { place(button, width: iconsOnly ? 24 : ceil(button.intrinsicContentSize.width) + 4, y: y) }
        }
        var left: CGFloat = isWindowed ? 80 : 8
        let showWorktree = navigation != nil && (isWindowed || width >= 600)
        worktreePicker.isHidden = !showWorktree || (navigation?.worktreePaths.count ?? 0) < 2
        worktreeLabel.isHidden = !showWorktree || !worktreePicker.isHidden
        separatorLabel.isHidden = !showWorktree
        if showWorktree {
            let control: NSView = worktreePicker.isHidden ? worktreeLabel : worktreePicker
            let desired = worktreePicker.isHidden ? worktreeLabel.intrinsicContentSize.width : worktreePicker.intrinsicContentSize.width
            let worktreeWidth = min(150, min(width * 0.2, desired + 4))
            control.frame = NSRect(x: left, y: y, width: worktreeWidth, height: 24)
            left += worktreeWidth + 4
            separatorLabel.frame = NSRect(x: left, y: y, width: 10, height: 24)
            left += 14
        }
        let fileRight = right
        if !previous.isHidden {
            if twoRows { right = width - 6 }
            place(next, width: 20, y: twoRows ? 4 : y)
            place(countLabel, width: ceil(countLabel.intrinsicContentSize.width) + 8, y: twoRows ? 4 : y)
            place(previous, width: 20, y: twoRows ? 4 : y)
        }
        let fileWidth = max(0, (twoRows ? fileRight : right) - left)
        // Leave unused header width with the drag handle instead of the menu.
        let pickerWidth = min(fileWidth, min(360, preferredPickerWidth))
        picker.frame = NSRect(x: left, y: y, width: pickerWidth, height: 24)
        filenameLabel.frame = NSRect(x: left, y: y, width: fileWidth, height: 24)
        for label in [filenameLabel, worktreeLabel, separatorLabel, countLabel] where !label.isHidden {
            label.frame.origin.y += 3
            label.frame.size.height = 18
        }
        let bottomInset = isWindowed ? 0.0 : 10.0
        quickLook.frame = NSRect(x: 0, y: bottomInset, width: width, height: max(0, bounds.height - headerHeight - bottomInset))
        errorLabel.frame = NSRect(x: 8, y: 12, width: max(0, width - 40), height: 36)
        bottom.frame = NSRect(x: 0, y: 0, width: max(0, width - 24), height: 10)
        grip.frame = NSRect(x: max(0, width - 24), y: 0, width: 24, height: 24)
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

/// Plain single-choice labels leave the header available for dragging.
final class PreviewDragLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
