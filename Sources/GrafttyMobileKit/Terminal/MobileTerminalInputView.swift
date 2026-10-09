#if canImport(UIKit)
import GhosttyTerminal
import UIKit

/// Keeps libghostty's input handler from echoing UIKit edits back to UIKit.
/// UITextInputDelegate notifications describe changes originating outside the
/// input system. Sending them during native typing or dictation can interrupt
/// the keyboard's current input session.
///
/// Retains software input context so UIKit can find and revise dictation's
/// previously committed hypotheses. Ghostty still renders and sends input.
final class MobileTerminalInputView: UITerminalView {
    private var systemEditDepth = 0
    // Ghostty only retains marked text. Dictation also reads back committed
    // hypotheses; an empty document makes UIKit cancel after the first word.
    // This is input context, not a copy of the remote terminal's screen.
    private var textContext = MobileTerminalTextContext()

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard super.gestureRecognizerShouldBegin(gestureRecognizer) else { return false }
        if gestureRecognizer is UIPanGestureRecognizer {
            // Finger scrolling has no pointer-hover event. Seed the position
            // before libghostty emits wheel input for mouse-reporting TUIs.
            let point = gestureRecognizer.location(in: self)
            surface?.sendMousePos(x: point.x, y: point.y)
        }
        return true
    }

    override var inputDelegate: (any UITextInputDelegate)? {
        get { systemEditDepth == 0 ? super.inputDelegate : nil }
        set { super.inputDelegate = newValue }
    }

    override func insertText(_ text: String) {
        guard isKeyboardInputEnabled else { return }
        #if !targetEnvironment(macCatalyst)
        if hasActiveStickyModifiers {
            withSystemEdit { super.insertText(text) }
            resetTextContext()
            return
        }
        #endif
        editTextContext { $0.insert(text) }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard isKeyboardInputEnabled else { return }
        #if !targetEnvironment(macCatalyst)
        if hasActiveStickyModifiers {
            withSystemEdit { super.setMarkedText(markedText, selectedRange: selectedRange) }
            resetTextContext()
            return
        }
        #endif
        editTextContext { $0.setMarkedText(markedText, selectedRange: selectedRange) }
    }

    override func unmarkText() {
        editTextContext { $0.markedRange = nil }
    }

    override func deleteBackward() {
        guard isKeyboardInputEnabled else { return }
        #if !targetEnvironment(macCatalyst)
        if hasActiveStickyModifiers {
            withSystemEdit { super.deleteBackward() }
            if textContext.markedRange != nil {
                textContext.deleteBackward()
            } else {
                resetTextContext()
            }
            return
        }
        #endif
        if textContext.text.isEmpty {
            withSystemEdit { super.deleteBackward() }
        } else {
            editTextContext { $0.deleteBackward() }
        }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        guard isKeyboardInputEnabled, let range = range as? MobileTerminalTextRange,
              textContext.contains(range.range) else { return }
        #if !targetEnvironment(macCatalyst)
        if hasActiveStickyModifiers {
            withSystemEdit { super.replace(range, withText: text) }
            resetTextContext()
            return
        }
        #endif
        editTextContext { $0.replace(range.range, with: text) }
    }

    override var selectedTextRange: UITextRange? {
        get { MobileTerminalTextRange(textContext.selection) }
        set {
            guard let range = newValue as? MobileTerminalTextRange,
                  textContext.contains(range.range) else { return }
            textContext.selection = range.range
            if textContext.markedRange != nil {
                withSystemEdit {
                    super.selectedTextRange = super.textRange(
                        from: nativePosition(for: range.start),
                        to: nativePosition(for: range.end)
                    )
                }
            }
        }
    }

    override var markedTextRange: UITextRange? {
        textContext.markedRange.map(MobileTerminalTextRange.init)
    }

    override var beginningOfDocument: UITextPosition { MobileTerminalTextPosition(0) }
    override var endOfDocument: UITextPosition { MobileTerminalTextPosition(textContext.length) }

    override func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? {
        guard let from = from as? MobileTerminalTextPosition,
              let to = to as? MobileTerminalTextPosition else { return nil }
        let range = NSRange(location: min(from.index, to.index), length: abs(to.index - from.index))
        return textContext.contains(range) ? MobileTerminalTextRange(range) : nil
    }

    override func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? MobileTerminalTextPosition else { return nil }
        let index = position.index + offset
        guard index >= 0, index <= textContext.length else { return nil }
        return MobileTerminalTextPosition(index)
    }

    override func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: direction == .left || direction == .up ? -offset : offset)
    }

    override func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let difference = offset(from: other, to: position)
        return difference < 0 ? .orderedAscending : difference > 0 ? .orderedDescending : .orderedSame
    }

    override func offset(from: UITextPosition, to: UITextPosition) -> Int {
        guard let from = from as? MobileTerminalTextPosition,
              let to = to as? MobileTerminalTextPosition else { return 0 }
        return to.index - from.index
    }

    override func text(in range: UITextRange) -> String? {
        guard let range = range as? MobileTerminalTextRange,
              textContext.contains(range.range) else { return nil }
        return (textContext.text as NSString).substring(with: range.range)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        super.caretRect(for: nativePosition(for: position))
    }

    override func firstRect(for range: UITextRange) -> CGRect {
        guard let native = super.textRange(from: nativePosition(for: range.start), to: nativePosition(for: range.end))
        else { return super.caretRect(for: super.beginningOfDocument) }
        return super.firstRect(for: native)
    }

    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let native = super.closestPosition(to: point) else { return nil }
        let origin = textContext.markedRange?.location ?? textContext.length
        return MobileTerminalTextPosition(origin + super.offset(from: super.beginningOfDocument, to: native))
    }

    override func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let position = closestPosition(to: point) as? MobileTerminalTextPosition,
              let range = range as? MobileTerminalTextRange else { return nil }
        return MobileTerminalTextPosition(min(max(position.index, range.range.location), NSMaxRange(range.range)))
    }

    override func characterRange(at point: CGPoint) -> UITextRange? {
        guard let position = closestPosition(to: point) else { return nil }
        return characterRange(byExtending: position, in: .right)
    }

    override func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? MobileTerminalTextPosition else { return nil }
        let index = direction == .left || direction == .up ? position.index - 1 : position.index
        guard index >= 0, index < textContext.length else {
            return textRange(from: position, to: position)
        }
        return MobileTerminalTextRange((textContext.text as NSString).rangeOfComposedCharacterSequence(at: index))
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        resetTextContext()
        return resigned
    }

    func resetTextContext() {
        textContext = MobileTerminalTextContext()
        withSystemEdit { super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0)) }
    }

    func commitAndResetTextContext() {
        unmarkText()
        resetTextContext()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Hardware navigation can move the remote cursor outside our software
        // input context. Ghostty still owns all physical-key translation.
        if textContext.markedRange == nil { resetTextContext() }
        super.pressesBegan(presses, with: event)
    }

    private func nativePosition(for position: UITextPosition) -> UITextPosition {
        guard let position = position as? MobileTerminalTextPosition,
              let marked = textContext.markedRange else { return super.beginningOfDocument }
        let index = min(max(position.index - marked.location, 0), marked.length)
        return super.position(from: super.beginningOfDocument, offset: index) ?? super.beginningOfDocument
    }

    private func editTextContext(_ edit: (inout MobileTerminalTextContext) -> Void) {
        let previous = textContext.committedText
        edit(&textContext)
        let committed = textContext.committedText
        // Revisions can replace a previous hypothesis. Only rewrite the changed
        // suffix, counting Unicode scalars for the terminal DEL transport
        // rather than UTF-16 units or Swift's composed Characters.
        let commonCount = zip(previous.unicodeScalars, committed.unicodeScalars).prefix { $0 == $1 }.count
        let removed = previous.unicodeScalars.dropFirst(commonCount)
        withSystemEdit {
            if !removed.isEmpty {
                super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
            }
            for _ in removed { super.deleteBackward() }
            let inserted = String(committed.unicodeScalars.dropFirst(commonCount))
            if !inserted.isEmpty { super.insertText(inserted) }
            super.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        }
        synchronizeMarkedText()
        if committed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            resetTextContext()
        }
    }

    private func synchronizeMarkedText() {
        withSystemEdit {
            guard let marked = textContext.markedRange else { return }
            let text = (textContext.text as NSString).substring(with: marked)
            let selection = textContext.selection
            super.setMarkedText(text, selectedRange: NSRange(
                location: min(max(selection.location - marked.location, 0), marked.length),
                length: min(selection.length, marked.length)
            ))
        }
    }

    private func withSystemEdit(_ edit: () -> Void) {
        systemEditDepth += 1
        defer { systemEditDepth -= 1 }
        edit()
    }
}

private struct MobileTerminalTextContext {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var markedRange: NSRange?
    var length: Int { text.utf16.count }
    var committedText: String {
        guard let markedRange else { return text }
        return (text as NSString).replacingCharacters(in: markedRange, with: "")
    }

    func contains(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
    }

    mutating func replace(_ range: NSRange, with replacement: String) {
        let previousMark = markedRange
        let previousSelection = selection
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        selection = NSRange(location: range.location + replacement.utf16.count, length: 0)
        markedRange = nil
        // UIKit can correct an earlier hypothesis while composing the next
        // word. A disjoint replacement must not commit that pending word.
        if let previousMark {
            if NSMaxRange(range) <= previousMark.location {
                let delta = replacement.utf16.count - range.length
                markedRange = NSRange(location: previousMark.location + delta, length: previousMark.length)
                let selectionDelta = previousSelection.location >= NSMaxRange(range) ? delta : 0
                selection = NSRange(location: previousSelection.location + selectionDelta, length: previousSelection.length)
            } else if range.location >= NSMaxRange(previousMark) {
                markedRange = previousMark
                selection = previousSelection
            }
        }
    }

    mutating func insert(_ text: String) {
        replace(markedRange ?? selection, with: text)
    }

    mutating func setMarkedText(_ text: String?, selectedRange: NSRange) {
        let range = markedRange ?? selection
        let replacement = text ?? ""
        replace(range, with: replacement)
        let length = replacement.utf16.count
        guard length > 0 else { return }
        markedRange = NSRange(location: range.location, length: length)
        let start = min(max(selectedRange.location, 0), length)
        selection = NSRange(location: range.location + start, length: min(max(selectedRange.length, 0), length - start))
    }

    mutating func deleteBackward() {
        var range = selection
        if range.length == 0 {
            guard range.location > 0 else { return }
            let prefix = (text as NSString).substring(to: range.location)
            guard let scalar = prefix.unicodeScalars.last else { return }
            let length = String(scalar).utf16.count
            range = NSRange(location: range.location - length, length: length)
        }
        let previousMark = markedRange
        replace(range, with: "")
        if let previousMark, range.location >= previousMark.location, NSMaxRange(range) <= NSMaxRange(previousMark) {
            let remaining = previousMark.length - range.length
            if remaining > 0 { markedRange = NSRange(location: previousMark.location, length: remaining) }
        }
    }
}

private final class MobileTerminalTextPosition: UITextPosition {
    let index: Int
    init(_ index: Int) { self.index = index; super.init() }
}

private final class MobileTerminalTextRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range; super.init() }
    override var start: UITextPosition { MobileTerminalTextPosition(range.location) }
    override var end: UITextPosition { MobileTerminalTextPosition(NSMaxRange(range)) }
    override var isEmpty: Bool { range.length == 0 }
}
#endif
