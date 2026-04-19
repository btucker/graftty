import Foundation
import GhosttyKit
import EspalierKit

/// Translates libghostty's `ghostty_input_trigger_s` into Espalier's
/// pure-Swift `ShortcutChord`. Lives in the app target because it's
/// the only module that imports GhosttyKit.
enum GhosttyTriggerAdapter {
    /// Returns nil when the trigger is unbound or maps to an enum value
    /// we don't have a string token for. Callers treat nil as "no
    /// shortcut hint" — the menu item still renders.
    static func chord(from trigger: ghostty_input_trigger_s) -> ShortcutChord? {
        let mods = modifiers(trigger.mods)
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            guard let key = keyString(trigger.key.physical) else { return nil }
            return ShortcutChord(key: key, modifiers: mods)
        case GHOSTTY_TRIGGER_UNICODE:
            // Ghostty stores `super+d`-style bindings as UNICODE triggers
            // carrying the codepoint. Delegate to ShortcutChord's
            // codepoint→token table so we cover letters, digits, and
            // punctuation (`[`, `]`, `=`, `,`, `.`, etc.).
            return ShortcutChord(codepoint: trigger.key.unicode, modifiers: mods)
        default:
            // GHOSTTY_TRIGGER_CATCH_ALL has no key payload; render menu
            // item without a shortcut hint.
            return nil
        }
    }

    /// Factory for the closure `GhosttyKeybindBridge.init(resolver:)`
    /// expects. Captures the `ghostty_config_t` and calls
    /// `ghostty_config_trigger` on each lookup.
    static func resolver(config: ghostty_config_t) -> GhosttyKeybindBridge.Resolver {
        { actionName in
            let trigger = actionName.withCString { cstr in
                ghostty_config_trigger(config, cstr, UInt(actionName.utf8.count))
            }
            return chord(from: trigger)
        }
    }

    // MARK: - Private

    private static func modifiers(_ raw: ghostty_input_mods_e) -> ShortcutModifiers {
        var out: ShortcutModifiers = []
        if (raw.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0 { out.insert(.shift) }
        if (raw.rawValue & GHOSTTY_MODS_CTRL.rawValue)  != 0 { out.insert(.control) }
        if (raw.rawValue & GHOSTTY_MODS_ALT.rawValue)   != 0 { out.insert(.option) }
        if (raw.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0 { out.insert(.command) }
        return out
    }

    private static func keyString(_ key: ghostty_input_key_e) -> String? {
        // Exhaustive mapping for key enum values libghostty can bind.
        // Returns nil for GHOSTTY_KEY_UNIDENTIFIED and anything unmapped.
        switch key {
        case GHOSTTY_KEY_A: return "a"
        case GHOSTTY_KEY_B: return "b"
        case GHOSTTY_KEY_C: return "c"
        case GHOSTTY_KEY_D: return "d"
        case GHOSTTY_KEY_E: return "e"
        case GHOSTTY_KEY_F: return "f"
        case GHOSTTY_KEY_G: return "g"
        case GHOSTTY_KEY_H: return "h"
        case GHOSTTY_KEY_I: return "i"
        case GHOSTTY_KEY_J: return "j"
        case GHOSTTY_KEY_K: return "k"
        case GHOSTTY_KEY_L: return "l"
        case GHOSTTY_KEY_M: return "m"
        case GHOSTTY_KEY_N: return "n"
        case GHOSTTY_KEY_O: return "o"
        case GHOSTTY_KEY_P: return "p"
        case GHOSTTY_KEY_Q: return "q"
        case GHOSTTY_KEY_R: return "r"
        case GHOSTTY_KEY_S: return "s"
        case GHOSTTY_KEY_T: return "t"
        case GHOSTTY_KEY_U: return "u"
        case GHOSTTY_KEY_V: return "v"
        case GHOSTTY_KEY_W: return "w"
        case GHOSTTY_KEY_X: return "x"
        case GHOSTTY_KEY_Y: return "y"
        case GHOSTTY_KEY_Z: return "z"
        case GHOSTTY_KEY_DIGIT_0: return "0"
        case GHOSTTY_KEY_DIGIT_1: return "1"
        case GHOSTTY_KEY_DIGIT_2: return "2"
        case GHOSTTY_KEY_DIGIT_3: return "3"
        case GHOSTTY_KEY_DIGIT_4: return "4"
        case GHOSTTY_KEY_DIGIT_5: return "5"
        case GHOSTTY_KEY_DIGIT_6: return "6"
        case GHOSTTY_KEY_DIGIT_7: return "7"
        case GHOSTTY_KEY_DIGIT_8: return "8"
        case GHOSTTY_KEY_DIGIT_9: return "9"
        default:
            // Fallthrough handles named/special keys via the second switch
            // so we can keep this one focused on letters + digits.
            return namedKey(key)
        }
    }

    private static func namedKey(_ key: ghostty_input_key_e) -> String? {
        // ghostty.h's key enum names may vary across libghostty-spm versions.
        // Keep this list guarded against missing enum cases by falling
        // through to nil at the end. If the vendored header is missing
        // one of these constants at build time, drop that case — the menu
        // item just won't have a shortcut hint, which is the documented
        // fallback behavior.
        switch key {
        case GHOSTTY_KEY_ARROW_LEFT:  return "arrowleft"
        case GHOSTTY_KEY_ARROW_RIGHT: return "arrowright"
        case GHOSTTY_KEY_ARROW_UP:    return "arrowup"
        case GHOSTTY_KEY_ARROW_DOWN:  return "arrowdown"
        case GHOSTTY_KEY_ENTER:       return "return"
        case GHOSTTY_KEY_TAB:         return "tab"
        case GHOSTTY_KEY_SPACE:       return "space"
        case GHOSTTY_KEY_ESCAPE:      return "escape"
        case GHOSTTY_KEY_BACKSPACE:   return "backspace"
        case GHOSTTY_KEY_DELETE:      return "delete"
        case GHOSTTY_KEY_HOME:        return "home"
        case GHOSTTY_KEY_END:         return "end"
        case GHOSTTY_KEY_PAGE_UP:     return "pageup"
        case GHOSTTY_KEY_PAGE_DOWN:   return "pagedown"
        case GHOSTTY_KEY_COMMA:       return "comma"
        case GHOSTTY_KEY_PERIOD:      return "period"
        case GHOSTTY_KEY_SEMICOLON:   return "semicolon"
        case GHOSTTY_KEY_QUOTE:       return "quote"
        case GHOSTTY_KEY_BRACKET_LEFT:  return "bracketleft"
        case GHOSTTY_KEY_BRACKET_RIGHT: return "bracketright"
        case GHOSTTY_KEY_SLASH:       return "slash"
        case GHOSTTY_KEY_BACKSLASH:   return "backslash"
        case GHOSTTY_KEY_BACKQUOTE:   return "backquote"
        case GHOSTTY_KEY_MINUS:       return "minus"
        case GHOSTTY_KEY_EQUAL:       return "equal"
        case GHOSTTY_KEY_F1:  return "f1"
        case GHOSTTY_KEY_F2:  return "f2"
        case GHOSTTY_KEY_F3:  return "f3"
        case GHOSTTY_KEY_F4:  return "f4"
        case GHOSTTY_KEY_F5:  return "f5"
        case GHOSTTY_KEY_F6:  return "f6"
        case GHOSTTY_KEY_F7:  return "f7"
        case GHOSTTY_KEY_F8:  return "f8"
        case GHOSTTY_KEY_F9:  return "f9"
        case GHOSTTY_KEY_F10: return "f10"
        case GHOSTTY_KEY_F11: return "f11"
        case GHOSTTY_KEY_F12: return "f12"
        default:
            return nil
        }
    }
}
