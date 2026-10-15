import AppKit

/// Right-click menu for a linked worktree's identity slot (its emoji, or
/// the branch icon while it has none).
enum WorktreeEmojiMenu {
    @MainActor
    static func build(hasEmoji: Bool, onChange: @escaping () -> Void, onClear: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: hasEmoji ? "Change Emoji…" : "Choose Emoji…", action: onChange))
        if hasEmoji { menu.addItem(ClosureMenuItem(title: "Clear Emoji", action: onClear)) }
        return menu
    }
}

/// Invisible first responder that receives the native emoji palette's
/// insertion. `NSApp.orderFrontCharacterPalette` inserts into whatever
/// `NSTextInputClient` is first responder, so this view stands in for a
/// text field, reports the identity slot's rect so the palette opens
/// beside it, delivers the first insertion, and then removes itself.
final class WorktreeEmojiPaletteCapture: NSView, NSTextInputClient {
    private let onPick: (String) -> Void
    private var delivered = false
    private weak var previousResponder: NSResponder?

    init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    /// Sits over `anchor` only so `firstRect(forCharacterRange:)` can
    /// place the palette; mouse events still reach the views beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @MainActor
    static func present(anchoredTo anchor: NSView,
                        showPalette: @escaping @MainActor () -> Void = { NSApp.orderFrontCharacterPalette(nil) },
                        onPick: @escaping (String) -> Void) {
        guard let window = anchor.window, let content = window.contentView else { return }
        let frame = content.convert(anchor.bounds, from: anchor)
        // Menu tracking can restore the previous responder after its action
        // returns. Wait until then to focus the capture and launch the picker.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible, let content = window.contentView else { return }
            (window.firstResponder as? WorktreeEmojiPaletteCapture)?.finish()
            window.makeKeyAndOrderFront(nil)
            let capture = WorktreeEmojiPaletteCapture(onPick: onPick)
            capture.frame = frame
            content.addSubview(capture)
            capture.previousResponder = window.firstResponder
            guard window.makeFirstResponder(capture) else { capture.removeFromSuperview(); return }
            capture.inputContext?.invalidateCharacterCoordinates()
            showPalette()
        }
    }

    private func finish() {
        if let window, window.firstResponder === self { window.makeFirstResponder(previousResponder) }
        removeFromSuperview()
    }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.removeFromSuperview() }
        return true
    }

    /// The palette inserts through `insertText` directly, so a key event
    /// can only be the user typing after dismissing it without a pick:
    /// release the capture and hand the key to the restored responder.
    override func keyDown(with event: NSEvent) {
        let window = window
        finish()
        if let responder = window?.firstResponder, responder !== self { responder.keyDown(with: event) }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !delivered else { return }
        delivered = true
        onPick((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
        finish()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
