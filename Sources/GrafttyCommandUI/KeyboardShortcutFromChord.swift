import SwiftUI
import GrafttyProtocol

/// Translates `ShortcutChord` into SwiftUI's `KeyboardShortcut`. Unmapped
/// keys return nil so callers can render the command without a shortcut hint.
public enum KeyboardShortcutFromChord {
    public static func shortcut(from chord: ShortcutChord) -> KeyboardShortcut? {
        guard let equivalent = keyEquivalent(from: chord.key) else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers(from: chord.modifiers))
    }

    private static func eventModifiers(from modifiers: ShortcutModifiers) -> EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.shift) {
            out.insert(.shift)
        }
        if modifiers.contains(.control) {
            out.insert(.control)
        }
        if modifiers.contains(.option) {
            out.insert(.option)
        }
        if modifiers.contains(.command) {
            out.insert(.command)
        }
        return out
    }

    private static func keyEquivalent(from token: String) -> KeyEquivalent? {
        if token.count == 1, let scalar = token.unicodeScalars.first {
            return KeyEquivalent(Character(scalar))
        }
        switch token {
        case "arrowleft":
            return .leftArrow
        case "arrowright":
            return .rightArrow
        case "arrowup":
            return .upArrow
        case "arrowdown":
            return .downArrow
        case "return":
            return .return
        case "tab":
            return .tab
        case "space":
            return .space
        case "escape":
            return .escape
        case "delete":
            return .deleteForward
        case "backspace":
            return .delete
        case "home":
            return .home
        case "end":
            return .end
        case "pageup":
            return .pageUp
        case "pagedown":
            return .pageDown
        default:
            return nil
        }
    }
}
