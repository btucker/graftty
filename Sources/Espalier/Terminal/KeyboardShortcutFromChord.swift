import SwiftUI
import EspalierKit

/// Translates `ShortcutChord` into SwiftUI's `KeyboardShortcut`. Unmapped
/// keys return nil — caller gracefully skips the `.keyboardShortcut(...)`
/// modifier so the menu item still renders without a hint.
enum KeyboardShortcutFromChord {
    static func shortcut(from chord: ShortcutChord) -> KeyboardShortcut? {
        guard let equivalent = keyEquivalent(from: chord.key) else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers(from: chord.modifiers))
    }

    private static func eventModifiers(from m: ShortcutModifiers) -> EventModifiers {
        var out: EventModifiers = []
        if m.contains(.shift)   { out.insert(.shift) }
        if m.contains(.control) { out.insert(.control) }
        if m.contains(.option)  { out.insert(.option) }
        if m.contains(.command) { out.insert(.command) }
        return out
    }

    private static func keyEquivalent(from token: String) -> KeyEquivalent? {
        if token.count == 1, let scalar = token.unicodeScalars.first {
            return KeyEquivalent(Character(scalar))
        }
        switch token {
        case "arrowleft":  return .leftArrow
        case "arrowright": return .rightArrow
        case "arrowup":    return .upArrow
        case "arrowdown":  return .downArrow
        case "return":     return .return
        case "tab":        return .tab
        case "space":      return .space
        case "escape":     return .escape
        case "delete":     return .deleteForward
        case "backspace":  return .delete
        case "home":       return .home
        case "end":        return .end
        case "pageup":     return .pageUp
        case "pagedown":   return .pageDown
        default:
            // Punctuation and f-keys: SwiftUI's KeyEquivalent has no
            // constants for most of these. The menu item will render
            // without a shortcut hint (acceptable fallback).
            return nil
        }
    }
}
