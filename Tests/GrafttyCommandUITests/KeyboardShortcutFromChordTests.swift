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
}
