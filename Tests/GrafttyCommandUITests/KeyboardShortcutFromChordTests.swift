import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@Suite("KeyboardShortcutFromChord")
struct KeyboardShortcutFromChordTests {
    @Test("returns shortcuts for supported shared chord tokens")
    func supportedChordTokens() {
        #expect(KeyboardShortcutFromChord.shortcut(from: .init(key: "tab", modifiers: [.control])) != nil)
        #expect(KeyboardShortcutFromChord.shortcut(from: .init(key: "arrowleft", modifiers: [.command, .option])) != nil)
    }

    @Test("returns nil for unsupported f-key tokens")
    func unsupportedFunctionKeyToken() {
        #expect(KeyboardShortcutFromChord.shortcut(from: .init(key: "f13", modifiers: [.command])) == nil)
    }

    @Test("translates every punctuation token ShortcutChord can emit")
    func punctuationTokens() {
        let tokenToCharacter: [String: Character] = [
            "comma": ",", "minus": "-", "period": ".", "slash": "/",
            "semicolon": ";", "equal": "=", "quote": "'",
            "bracketleft": "[", "backslash": "\\", "bracketright": "]",
            "backquote": "`",
        ]
        for (token, character) in tokenToCharacter {
            let shortcut = KeyboardShortcutFromChord.shortcut(from: .init(key: token, modifiers: [.command]))
            #expect(
                shortcut == KeyboardShortcut(KeyEquivalent(character), modifiers: [.command]),
                "token \(token) should map to \(character)"
            )
        }
    }
}
