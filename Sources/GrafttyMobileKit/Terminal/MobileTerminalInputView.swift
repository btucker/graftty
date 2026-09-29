#if canImport(UIKit)
import GhosttyTerminal
import UIKit

/// Keeps libghostty's input handler from echoing UIKit edits back to UIKit.
/// UITextInputDelegate notifications describe changes originating outside the
/// input system. Sending them during native typing or dictation can interrupt
/// the keyboard's current input session.
///
/// This adapter can be removed when libghostty-spm observes that distinction.
final class MobileTerminalInputView: UITerminalView {
    private var systemEditDepth = 0

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
        withSystemEdit { super.insertText(text) }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        withSystemEdit { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }

    override func unmarkText() {
        withSystemEdit { super.unmarkText() }
    }

    override func deleteBackward() {
        withSystemEdit { super.deleteBackward() }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        withSystemEdit { super.replace(range, withText: text) }
    }

    override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set { withSystemEdit { super.selectedTextRange = newValue } }
    }

    private func withSystemEdit(_ edit: () -> Void) {
        systemEditDepth += 1
        defer { systemEditDepth -= 1 }
        edit()
    }
}
#endif
