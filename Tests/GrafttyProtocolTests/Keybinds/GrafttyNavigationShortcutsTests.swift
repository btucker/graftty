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

    @Test("fixed worktree wins when all candidate sources collide")
    func fixedWorktreeWinsCollision() {
        let candidates = [
            GrafttyNavigationShortcuts.SourcedCandidate(source: .host, value: "host"),
            GrafttyNavigationShortcuts.SourcedCandidate(source: .fixedPane, value: "pane"),
            GrafttyNavigationShortcuts.SourcedCandidate(source: .fixedWorktree, value: "worktree"),
        ]

        let winners = GrafttyNavigationShortcuts.collisionWinners(
            from: candidates,
            identifiedBy: { _ in "tab" }
        )

        #expect(winners.map(\.value) == ["worktree"])
    }

    @Test("noncolliding host candidates survive after fixed sources in stable order")
    func noncollidingHostCandidatesSurvive() {
        let candidates = [
            GrafttyNavigationShortcuts.SourcedCandidate(source: .host, value: "host-first"),
            GrafttyNavigationShortcuts.SourcedCandidate(source: .fixedPane, value: "pane"),
            GrafttyNavigationShortcuts.SourcedCandidate(source: .host, value: "host-second"),
            GrafttyNavigationShortcuts.SourcedCandidate(source: .fixedWorktree, value: "worktree"),
        ]

        let winners = GrafttyNavigationShortcuts.collisionWinners(
            from: candidates,
            identifiedBy: { $0 }
        )

        #expect(winners.map(\.value) == ["worktree", "pane", "host-first", "host-second"])
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
