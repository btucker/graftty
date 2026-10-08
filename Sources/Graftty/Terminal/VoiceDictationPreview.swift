import AppKit

/// A wrapping caption keeps provisional speech readable without changing PTY input.
final class VoiceDictationPreview: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let padding: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: padding, height: padding)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.setAccessibilityLabel("Live dictation")
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func update(_ text: String, in paneBounds: NSRect, cursorRect: NSRect) {
        textView.string = text
        fit(in: paneBounds, cursorRect: cursorRect)
    }

    func fit(in paneBounds: NSRect, cursorRect: NSRect) {
        let margin: CGFloat = 12
        let width = max(0, paneBounds.width - 2 * margin)
        let availableHeight = max(0, paneBounds.height - 2 * margin)
        guard width > 2 * padding, availableHeight > 0,
              let container = textView.textContainer, let manager = textView.layoutManager else {
            isHidden = true
            return
        }
        isHidden = false
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        container.containerSize = NSSize(width: width - 2 * padding, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let textHeight = ceil(manager.usedRect(for: container).height) + 2 * padding
        // A resize can briefly leave Ghostty's cursor outside the new bounds.
        let cursorTop = min(max(cursorRect.maxY, paneBounds.minY + margin), paneBounds.maxY - margin)
        let cursorBottom = min(max(cursorRect.minY, paneBounds.minY + margin), paneBounds.maxY - margin)
        let above = max(0, paneBounds.maxY - margin - cursorTop - 8)
        let below = max(0, cursorBottom - 8 - paneBounds.minY - margin)
        let useAbove = above >= below
        let space = useAbove ? above : below
        guard let font = textView.font,
              space >= ceil(manager.defaultLineHeight(for: font)) + 2 * padding else {
            isHidden = true
            return
        }
        let height = min(textHeight, availableHeight, space, max(44, paneBounds.height / 2))
        // Keep the caption off the cursor's row. Long speech scrolls to its
        // latest words.
        let y = useAbove ? cursorTop + 8 : cursorBottom - 8 - height
        frame = NSRect(x: paneBounds.minX + margin, y: y,
                       width: width, height: height)
        scrollView.frame = bounds
        textView.setFrameSize(NSSize(width: width, height: textHeight))
        textView.scrollRangeToVisible(NSRange(location: textView.string.utf16.count, length: 0))
    }
}
