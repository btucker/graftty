import SwiftUI
import GrafttyCommandUI
import GrafttyProtocol

struct NavigationCommandShortcutPolicy {
    struct FixedCommand: Sendable, Hashable {
        let label: String
        let forward: Bool
        let chord: ShortcutChord
    }

    struct FixedWorktreeCommandDescriptor {
        let label: String
        let chord: ShortcutChord
        let shortcut: KeyboardShortcut
        let perform: () -> Void
    }

    static let fixedPaneCommands = [
        FixedCommand(label: "Next Pane", forward: true, chord: GrafttyNavigationShortcuts.nextPane),
        FixedCommand(label: "Previous Pane", forward: false, chord: GrafttyNavigationShortcuts.previousPane),
    ]

    static let fixedWorktreeCommands = [
        FixedCommand(label: "Next Worktree", forward: true, chord: GrafttyNavigationShortcuts.nextWorktree),
        FixedCommand(label: "Previous Worktree", forward: false, chord: GrafttyNavigationShortcuts.previousWorktree),
    ]

    static func fixedWorktreeCommandDescriptors(
        action: ((Bool) -> Void)?
    ) -> [FixedWorktreeCommandDescriptor] {
        fixedWorktreeCommands.map { command in
            guard let shortcut = KeyboardShortcutFromChord.shortcut(from: command.chord) else {
                preconditionFailure("Fixed worktree shortcut must be representable")
            }
            return FixedWorktreeCommandDescriptor(
                label: command.label,
                chord: command.chord,
                shortcut: shortcut,
                perform: { action?(command.forward) }
            )
        }
    }

    private struct ShortcutCandidate {
        let action: GhosttyAction?
        let shortcut: KeyboardShortcut
    }

    static func hostShortcutWinners(
        commands: [GhosttyCommandRegistry.Entry],
        bridge: GhosttyKeybindBridge
    ) -> [GhosttyAction: KeyboardShortcut] {
        let fixedWorktreeCandidates = fixedWorktreeCommands.compactMap { command in
            KeyboardShortcutFromChord.shortcut(from: command.chord).map { shortcut in
                GrafttyNavigationShortcuts.SourcedCandidate(
                    source: .fixedWorktree,
                    value: ShortcutCandidate(action: nil, shortcut: shortcut)
                )
            }
        }
        let fixedPaneCandidates = fixedPaneCommands.compactMap { command in
            KeyboardShortcutFromChord.shortcut(from: command.chord).map { shortcut in
                GrafttyNavigationShortcuts.SourcedCandidate(
                    source: .fixedPane,
                    value: ShortcutCandidate(action: nil, shortcut: shortcut)
                )
            }
        }
        let hostCandidates: [GrafttyNavigationShortcuts.SourcedCandidate<ShortcutCandidate>] =
            commands.compactMap { command in
                guard let chord = bridge[command.action],
                      let shortcut = KeyboardShortcutFromChord.shortcut(from: chord) else {
                    return nil
                }
                return GrafttyNavigationShortcuts.SourcedCandidate(
                    source: .host,
                    value: ShortcutCandidate(action: command.action, shortcut: shortcut)
                )
            }
        let winners = GrafttyNavigationShortcuts.collisionWinners(
            from: fixedWorktreeCandidates + fixedPaneCandidates + hostCandidates,
            identifiedBy: { $0.shortcut }
        )
        return winners.reduce(into: [:]) { shortcuts, winner in
            guard winner.source == .host, let action = winner.value.action else { return }
            shortcuts[action] = winner.value.shortcut
        }
    }
}

/// Scene-scoped command exposed by `MainWindow` so the `.commands` block in
/// `GrafttyApp` (which can't reach view-local state) can drive worktree
/// navigation. The `Bool` is `forward`. A nil value is a valid no-op state;
/// fixed worktree chords remain reserved so they cannot leak to the terminal.
struct WorktreeNavActionKey: FocusedValueKey {
    typealias Value = (_ forward: Bool) -> Void
}

extension FocusedValues {
    var worktreeNavAction: ((Bool) -> Void)? {
        get { self[WorktreeNavActionKey.self] }
        set { self[WorktreeNavActionKey.self] = newValue }
    }
}

struct WorktreeNavCommandButtons: View {
    @FocusedValue(\.worktreeNavAction) private var action: ((Bool) -> Void)?

    var body: some View {
        Group {
            ForEach(
                NavigationCommandShortcutPolicy.fixedWorktreeCommandDescriptors(action: action),
                id: \.label
            ) { command in
                Button(command.label, action: command.perform)
                    .keyboardShortcut(command.shortcut)
            }
        }
    }
}
