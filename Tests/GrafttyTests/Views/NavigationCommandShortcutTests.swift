import GrafttyCommandUI
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
        let command = GhosttyCommandRegistry[.nextTab]!
        let bridge = GhosttyKeybindBridge(chords: [.nextTab: chord])

        #expect(NavigationCommandShortcutPolicy.hostShortcutWinners(
            commands: [command],
            bridge: bridge
        )[.nextTab] == KeyboardShortcutFromChord.shortcut(from: chord))
    }

    @Test("first host command keeps a shared non-fixed shortcut and later menu action remains")
    func firstHostCommandWinsHostCollision() {
        let commands = [
            GhosttyCommandRegistry[.newSplitRight]!,
            GhosttyCommandRegistry[.nextTab]!,
        ]
        let chord = ShortcutChord(key: "period", modifiers: [.command])
        let bridge = GhosttyKeybindBridge(chords: [
            .newSplitRight: chord,
            .nextTab: chord,
        ])

        let winners = NavigationCommandShortcutPolicy.hostShortcutWinners(
            commands: commands,
            bridge: bridge
        )

        #expect(winners[.newSplitRight] == KeyboardShortcutFromChord.shortcut(from: chord))
        #expect(winners[.nextTab] == nil)
        #expect(commands.map(\.action) == [.newSplitRight, .nextTab])
    }

    @Test("every fixed chord suppresses a colliding host keyboard shortcut")
    func fixedChordsWinHostCollisions() {
        for chord in NavigationCommandShortcutPolicy.fixedPaneCommands.map(\.chord)
            + NavigationCommandShortcutPolicy.fixedWorktreeCommands.map(\.chord) {
            let command = GhosttyCommandRegistry[.nextTab]!
            let bridge = GhosttyKeybindBridge(chords: [.nextTab: chord])
            #expect(NavigationCommandShortcutPolicy.hostShortcutWinners(
                commands: [command],
                bridge: bridge
            )[.nextTab] == nil)
        }
    }

    @Test("fixed worktree projection reserves both shortcuts without a focused action")
    func fixedWorktreeProjectionIsStableWithoutAction() throws {
        let action: ((Bool) -> Void)? = nil
        let descriptors = NavigationCommandShortcutPolicy.fixedWorktreeCommandDescriptors(
            action: action
        )
        let nextShortcut = try #require(KeyboardShortcutFromChord.shortcut(
            from: GrafttyNavigationShortcuts.nextWorktree
        ))
        let previousShortcut = try #require(KeyboardShortcutFromChord.shortcut(
            from: GrafttyNavigationShortcuts.previousWorktree
        ))

        #expect(descriptors.map(\.chord) == [
            GrafttyNavigationShortcuts.nextWorktree,
            GrafttyNavigationShortcuts.previousWorktree,
        ])
        #expect(descriptors.map(\.shortcut) == [
            nextShortcut,
            previousShortcut,
        ])
        descriptors.forEach { $0.perform() }
    }
}
