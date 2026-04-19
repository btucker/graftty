import Testing
@testable import EspalierKit

@Suite("ShortcutChord")
struct ShortcutChordTests {
    @Test func modifiersOptionSetCombines() {
        let m: ShortcutModifiers = [.command, .shift]
        #expect(m.contains(.command))
        #expect(m.contains(.shift))
        #expect(!m.contains(.option))
    }

    @Test func chordEqualityIgnoresNothing() {
        let a = ShortcutChord(key: "d", modifiers: [.command])
        let b = ShortcutChord(key: "d", modifiers: [.command])
        let c = ShortcutChord(key: "d", modifiers: [.command, .shift])
        #expect(a == b)
        #expect(a != c)
    }

    // Unicode-trigger decoding — covers the libghostty `GHOSTTY_TRIGGER_UNICODE`
    // path used for `super+d=new_split:right`-style defaults. Prior to this,
    // the adapter dropped every UNICODE trigger, leaving menu items without
    // their keyboard shortcuts despite Ghostty exposing them.

    @Test func codepointLowercaseLetterMapsToTokenAndPreservesModifiers() {
        let chord = ShortcutChord(codepoint: 0x64, modifiers: [.command])
        #expect(chord == ShortcutChord(key: "d", modifiers: [.command]))
    }

    @Test func codepointUppercaseLetterNormalizesToLowercaseToken() {
        // Ghostty typically splits case off into the mods bitfield, but the
        // adapter must not break if the codepoint lands uppercase.
        let chord = ShortcutChord(codepoint: 0x44, modifiers: [.command, .shift])
        #expect(chord == ShortcutChord(key: "d", modifiers: [.command, .shift]))
    }

    @Test func codepointDigitMapsToDigitToken() {
        let chord = ShortcutChord(codepoint: 0x31, modifiers: [.command])
        #expect(chord == ShortcutChord(key: "1", modifiers: [.command]))
    }

    @Test func codepointBracketsMapToNamedTokens() {
        // Ghostty's super+[=goto_split:previous and super+]=goto_split:next
        // defaults.
        let left  = ShortcutChord(codepoint: 0x5B, modifiers: [.command])
        let right = ShortcutChord(codepoint: 0x5D, modifiers: [.command])
        #expect(left  == ShortcutChord(key: "bracketleft",  modifiers: [.command]))
        #expect(right == ShortcutChord(key: "bracketright", modifiers: [.command]))
    }

    @Test func codepointEqualsMapsForEqualizeSplits() {
        // Ghostty's super+ctrl+==equalize_splits default.
        let chord = ShortcutChord(codepoint: 0x3D, modifiers: [.command, .control])
        #expect(chord == ShortcutChord(key: "equal", modifiers: [.command, .control]))
    }

    @Test func codepointCommaMapsForReloadConfig() {
        // Ghostty's super+shift+,=reload_config default.
        let chord = ShortcutChord(codepoint: 0x2C, modifiers: [.command, .shift])
        #expect(chord == ShortcutChord(key: "comma", modifiers: [.command, .shift]))
    }

    @Test func codepointUnmappableReturnsNil() {
        // DEL (0x7F) and other unprintables don't have a sensible token —
        // caller expected to fall back to "no shortcut hint".
        #expect(ShortcutChord(codepoint: 0x7F, modifiers: []) == nil)
        #expect(ShortcutChord(codepoint: 0x01, modifiers: []) == nil)
    }
}
