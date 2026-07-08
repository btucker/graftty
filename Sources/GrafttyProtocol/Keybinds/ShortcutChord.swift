import Foundation

public struct ShortcutModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift   = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option  = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
}

/// A keyboard chord: the key plus the modifier set.
///
/// `key` is a short printable token identifying the physical key:
/// lowercase letters `"a"`..`"z"`; digits `"0"`..`"9"`; `"arrowleft"`,
/// `"arrowright"`, `"arrowup"`, `"arrowdown"`; `"return"`, `"tab"`,
/// `"space"`, `"escape"`, `"backspace"`, `"delete"`; `"f1"`..`"f24"`;
/// plus punctuation tokens. The app-target adapter produces these from
/// `ghostty_input_trigger_s` and the SwiftUI translator consumes them.
public struct ShortcutChord: Hashable, Sendable, Codable {
    public let key: String
    public let modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Builds a chord from a Unicode codepoint (as libghostty emits for
    /// `GHOSTTY_TRIGGER_UNICODE` bindings such as `super+d=new_split:right`).
    /// Returns nil for codepoints that don't map to one of this type's
    /// key tokens (letters, digits, common ASCII punctuation).
    public init?(codepoint: UInt32, modifiers: ShortcutModifiers) {
        guard let key = Self.keyToken(forCodepoint: codepoint) else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    static func keyToken(forCodepoint codepoint: UInt32) -> String? {
        // Normalize A-Z to a-z so the token matches the PHYSICAL letter tokens.
        // Ghostty's UNICODE triggers for shifted letters still carry the lowercase
        // codepoint (shift is in mods), but map uppercase defensively.
        switch codepoint {
        case 0x41...0x5A: return String(UnicodeScalar(codepoint + 0x20)!)
        case 0x61...0x7A, 0x30...0x39: return String(UnicodeScalar(codepoint)!)
        case 0x20: return "space"
        case 0x2C: return "comma"
        case 0x2D: return "minus"
        case 0x2E: return "period"
        case 0x2F: return "slash"
        case 0x3B: return "semicolon"
        case 0x3D: return "equal"
        case 0x27: return "quote"
        case 0x5B: return "bracketleft"
        case 0x5C: return "backslash"
        case 0x5D: return "bracketright"
        case 0x60: return "backquote"
        default: return nil
        }
    }
}
