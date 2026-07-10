import GrafttyProtocol
import SwiftUI
import Testing
@testable import Graftty

@Suite("Navigation command shortcut policy")
struct NavigationCommandShortcutTests {
    @Test("fixed pane and worktree commands use app chords")
    func fixedCommands() {
        #expect(NavigationCommandShortcutPolicy.fixedPaneCommands.map(\.chord) == [
            GrafttyNavigationShortcuts.nextPane,
            GrafttyNavigationShortcuts.previousPane,
        ])
        #expect(NavigationCommandShortcutPolicy.fixedWorktreeCommands.map(\.chord) == [
            GrafttyNavigationShortcuts.nextWorktree,
            GrafttyNavigationShortcuts.previousWorktree,
        ])
    }

    @Test("noncolliding host tab chord remains an additional pane shortcut")
    func noncollidingHostChordSurvives() {
        let chord = ShortcutChord(key: "period", modifiers: [.command])

        #expect(NavigationCommandShortcutPolicy.hostChordIfNoncolliding(chord) == chord)
    }

    @Test("every fixed chord suppresses a colliding host keyboard shortcut")
    func fixedChordsWinHostCollisions() {
        for chord in NavigationCommandShortcutPolicy.fixedPaneCommands.map(\.chord)
            + NavigationCommandShortcutPolicy.fixedWorktreeCommands.map(\.chord) {
            #expect(NavigationCommandShortcutPolicy.hostChordIfNoncolliding(chord) == nil)
        }
    }

    @Test("fixed worktree reservations do not depend on a focused action")
    func fixedWorktreeReservationIsStableWithoutAction() {
        let action: ((Bool) -> Void)? = nil

        #expect(NavigationCommandShortcutPolicy.fixedWorktreeCommands.count == 2)
        NavigationCommandShortcutPolicy.perform(action: action, forward: true)
        NavigationCommandShortcutPolicy.perform(action: action, forward: false)
    }
}
