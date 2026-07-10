import Testing
@testable import GrafttyProtocol

@Suite("GrafttyNavigationShortcuts")
struct GrafttyNavigationShortcutsTests {
    @Test("fixed pane and worktree chords are exact")
    func fixedChords() {
        #expect(GrafttyNavigationShortcuts.nextPane == ShortcutChord(key: "tab", modifiers: [.control]))
        #expect(GrafttyNavigationShortcuts.previousPane == ShortcutChord(key: "tab", modifiers: [.control, .shift]))
        #expect(GrafttyNavigationShortcuts.nextWorktree == ShortcutChord(key: "tab", modifiers: [.control, .option]))
        #expect(GrafttyNavigationShortcuts.previousWorktree == ShortcutChord(key: "tab", modifiers: [.control, .option, .shift]))
    }

    @Test("collision precedence is fixed worktree, fixed pane, then host")
    func collisionPrecedence() {
        #expect(GrafttyNavigationShortcuts.collisionPrecedence == [
            .fixedWorktree,
            .fixedPane,
            .host,
        ])
    }

    @Test("fixed pane aliases are independent of host remaps and unbinds")
    func fixedPaneAliasesAreIndependentOfHostBindings() {
        let remappedHost = GhosttyKeybindBridge(chords: [
            .nextTab: ShortcutChord(key: "n", modifiers: [.command]),
            .previousTab: ShortcutChord(key: "p", modifiers: [.command]),
        ])
        let unboundHost = GhosttyKeybindBridge(chords: [:])

        #expect(remappedHost[.nextTab] != GrafttyNavigationShortcuts.nextPane)
        #expect(remappedHost[.previousTab] != GrafttyNavigationShortcuts.previousPane)
        #expect(unboundHost[.nextTab] == nil)
        #expect(unboundHost[.previousTab] == nil)
        #expect(GrafttyNavigationShortcuts.nextPane == ShortcutChord(key: "tab", modifiers: [.control]))
        #expect(GrafttyNavigationShortcuts.previousPane == ShortcutChord(key: "tab", modifiers: [.control, .shift]))
    }
}
