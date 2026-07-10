import Testing
@testable import GrafttyProtocol

@Suite("""
@spec IPAD-9.8: The bundled Ghostty default keybinding table shall mirror the defaults reported by ghostty +list-keybinds --default for every iPad-supported action, leaving new_split:left and new_split:up chordless because Ghostty ships no default binding for them.
""")
struct GhosttyDefaultKeybindsTests {
    @Test func pinsEveryDefaultChordExactly() {
        #expect(GhosttyDefaultKeybinds.chords == [
            .newSplitRight: ShortcutChord(key: "d", modifiers: [.command]),
            .newSplitDown: ShortcutChord(key: "d", modifiers: [.command, .shift]),
            .closeSurface: ShortcutChord(key: "w", modifiers: [.command]),
            .gotoSplitLeft: ShortcutChord(key: "arrowleft", modifiers: [.command, .option]),
            .gotoSplitRight: ShortcutChord(key: "arrowright", modifiers: [.command, .option]),
            .gotoSplitUp: ShortcutChord(key: "arrowup", modifiers: [.command, .option]),
            .gotoSplitDown: ShortcutChord(key: "arrowdown", modifiers: [.command, .option]),
            .gotoSplitPrevious: ShortcutChord(key: "bracketleft", modifiers: [.command]),
            .gotoSplitNext: ShortcutChord(key: "bracketright", modifiers: [.command]),
            .previousTab: ShortcutChord(key: "bracketleft", modifiers: [.command, .shift]),
            .nextTab: ShortcutChord(key: "bracketright", modifiers: [.command, .shift]),
        ])
    }

    @Test func coversExactlyTheBoundIPadSupportedActions() {
        let ghosttyUnbound: Set<GhosttyAction> = [.newSplitLeft, .newSplitUp]
        #expect(
            Set(GhosttyDefaultKeybinds.chords.keys)
                == Set(GhosttyCommandRegistry.iPadSupportedActions).subtracting(ghosttyUnbound)
        )
    }

    @Test func bridgeExposesExactlyTheDefaultTable() {
        #expect(GhosttyDefaultKeybinds.bridge.allChords == GhosttyDefaultKeybinds.chords)
    }

    @Test func nextTabHardwareChordsPutPrimaryBeforeAlias() {
        #expect(GhosttyDefaultKeybinds.hardwareChords(for: .nextTab) == [
            ShortcutChord(key: "bracketright", modifiers: [.command, .shift]),
            ShortcutChord(key: "tab", modifiers: [.control]),
        ])
    }

    @Test func previousTabHardwareChordsPutPrimaryBeforeAlias() {
        #expect(GhosttyDefaultKeybinds.hardwareChords(for: .previousTab) == [
            ShortcutChord(key: "bracketleft", modifiers: [.command, .shift]),
            ShortcutChord(key: "tab", modifiers: [.control, .shift]),
        ])
    }

    @Test func hardwareChordsReturnOnlyPrimaryWhenNoAliasesExist() {
        #expect(GhosttyDefaultKeybinds.hardwareChords(for: .newSplitRight) == [
            ShortcutChord(key: "d", modifiers: [.command]),
        ])
    }

    @Test func hardwareChordsAreEmptyForUnboundActions() {
        #expect(GhosttyDefaultKeybinds.hardwareChords(for: .newSplitLeft).isEmpty)
    }
}
