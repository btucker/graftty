import AppKit

/// The editable document is only the current composition. Terminal output and
/// previously committed input cannot be replaced through AppKit text ranges.
extension SurfaceNSView: NSTextInputClient {
    var canReceiveNativeText: Bool {
        surface != nil && !isReadonly && acceptsCompositionCallbacks
            && window?.firstResponder === self
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { markedSelection }

    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard canReceiveNativeText, let text = Self.attributedInput(value),
              let range = compositionReplacementRange(replacementRange) else { return }
        let updated = NSMutableAttributedString(attributedString: markedText)
        updated.replaceCharacters(in: range, with: text)
        markedText = updated
        let location = min(max(0, selectedRange.location), text.length)
        let length = min(max(0, selectedRange.length), text.length - location)
        markedSelection = NSRange(location: range.location + location, length: length)
        if let surface { surfaceOperations.preedit(surface, updated.string) }
        inputContext?.invalidateCharacterCoordinates()
    }

    func insertText(_ value: Any, replacementRange: NSRange) {
        guard canReceiveNativeText, let input = Self.attributedInput(value),
              let range = compositionReplacementRange(replacementRange) else { return }
        let committed: String
        if replacementRange.location == NSNotFound {
            committed = input.string
        } else {
            let updated = NSMutableAttributedString(attributedString: markedText)
            updated.replaceCharacters(in: range, with: input)
            committed = updated.string
        }
        unmarkText()
        // Native text insertion is single-line. A spoken newline must not
        // execute a shell command; control bytes must not act as terminal keys.
        let text = Self.singleLineNativeText(committed)
        guard !text.isEmpty, let surface else { return }
        if canTakeDisplayControlNotifier?() == true {
            guard takeDisplayControlNotifier?() == true else {
                NSSound.beep()
                return
            }
        }
        let deliver = { self.surfaceOperations.text(surface, text) }
        if let hostManagedUserInputScope { hostManagedUserInputScope(deliver) }
        else { deliver() }
    }

    func unmarkText() {
        let hadText = hasMarkedText()
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        if hadText, let surface { surfaceOperations.preedit(surface, "") }
    }

    func cancelTextComposition() {
        // Reject synchronous callbacks while asking the system to discard its
        // composition. In particular, cancellation must not commit old text.
        let wasAccepting = acceptsCompositionCallbacks
        acceptsCompositionCallbacks = false
        let hadText = hasMarkedText()
        unmarkText()
        if hadText { inputContext?.discardMarkedText() }
        acceptsCompositionCallbacks = wasAccepting
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        guard range.location != NSNotFound, range.location >= 0,
              range.length > 0, range.location < markedText.length else { return nil }
        let available = NSRange(location: range.location, length: min(range.length, markedText.length - range.location))
        let result = (markedText.string as NSString).rangeOfComposedCharacterSequences(for: available)
        actualRange?.pointee = result
        return markedText.attributedSubstring(from: result)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = selectedRange()
        guard let surface else { return .zero }
        var rect = surfaceOperations.imeRect(surface)
        rect.origin.y = bounds.height - rect.origin.y
        if range.length == 0 { rect.size.width = 0 }
        let windowRect = convert(rect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    var unionRectInVisibleSelectedRange: NSRect {
        firstRect(forCharacterRange: selectedRange(), actualRange: nil)
    }

    var documentVisibleRect: NSRect {
        let rect = convert(visibleRect, to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    private func compositionReplacementRange(_ range: NSRange) -> NSRange? {
        if range.location == NSNotFound { return NSRange(location: 0, length: markedText.length) }
        guard range.location >= 0, range.length >= 0, range.location <= markedText.length,
              range.length <= markedText.length - range.location else { return nil }
        return range
    }

    private static func attributedInput(_ value: Any) -> NSAttributedString? {
        if let text = value as? NSAttributedString { return text }
        if let text = value as? String { return NSAttributedString(string: text) }
        return nil
    }

    nonisolated static func singleLineNativeText(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines).joined(separator: " ")
        return String(line.unicodeScalars.filter { $0.properties.generalCategory != .control })
    }
}
