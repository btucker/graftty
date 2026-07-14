#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

enum MobileGhosttyCommandSemantic: Sendable, Hashable {
    case ghostty(GhosttyAction)
    case navigateWorktree(forward: Bool)
}

struct MobileGhosttyCommandContext {
    let keybindingSet: MobileGhosttyKeybindingSet
    let perform: (MobileGhosttyCommandSemantic) -> Void
    let isEnabled: (GhosttyAction) -> Bool
}

struct MobileGhosttyCommandDescriptor {
    let id: String
    let semantic: MobileGhosttyCommandSemantic
    let label: String
    let shortcut: KeyboardShortcut
    let input: String
    let modifierFlags: UIKeyModifierFlags
}

private struct MobileGhosttyCommandCandidate {
    let semantic: MobileGhosttyCommandSemantic
    let label: String
    let shortcut: KeyboardShortcut
    let input: String
    let modifierFlags: UIKeyModifierFlags

    var id: String {
        "\(semantic.idComponent)|\(input)|\(modifierFlags.rawValue)"
    }
}

private extension MobileGhosttyCommandSemantic {
    var idComponent: String {
        switch self {
        case let .ghostty(action):
            return action.rawValue
        case let .navigateWorktree(forward):
            return forward ? "next_worktree" : "previous_worktree"
        }
    }
}

private struct MobileGhosttyCommandChord: Hashable {
    let input: String
    let modifierRawValue: UIKeyModifierFlags.RawValue
}

struct MobileGhosttyCommandContextKey: FocusedValueKey {
    typealias Value = MobileGhosttyCommandContext
}

extension FocusedValues {
    var mobileGhosttyCommandContext: MobileGhosttyCommandContext? {
        get { self[MobileGhosttyCommandContextKey.self] }
        set { self[MobileGhosttyCommandContextKey.self] = newValue }
    }
}

struct MobileGhosttyCommandButtons: View {
    @FocusedValue(\.mobileGhosttyCommandContext) private var context: MobileGhosttyCommandContext?

    var body: some View {
        Group {
            if let context {
                ForEach(Self.renderableCommands(for: context), id: \.id) { command in
                    Button(command.label) {
                        context.perform(command.semantic)
                    }
                    .keyboardShortcut(command.shortcut)
                }
            }
        }
    }

    static func renderableCommands(
        for context: MobileGhosttyCommandContext
    ) -> [MobileGhosttyCommandDescriptor] {
        commandCandidates(for: context).map { candidate in
            return MobileGhosttyCommandDescriptor(
                id: candidate.id,
                semantic: candidate.semantic,
                label: candidate.label,
                shortcut: candidate.shortcut,
                input: candidate.input,
                modifierFlags: candidate.modifierFlags
            )
        }
    }

    static func hardwareKeyboardCommands(
        for context: MobileGhosttyCommandContext
    ) -> [TerminalPaneView.HardwareKeyboardCommand] {
        commandCandidates(for: context).map { candidate in
            return TerminalPaneView.HardwareKeyboardCommand(
                id: candidate.id,
                title: candidate.label,
                input: candidate.input,
                modifierFlags: candidate.modifierFlags,
                perform: { context.perform(candidate.semantic) }
            )
        }
    }

    private static func commandCandidates(
        for context: MobileGhosttyCommandContext
    ) -> [MobileGhosttyCommandCandidate] {
        let fixedCandidates = [
            commandCandidate(
                semantic: .navigateWorktree(forward: true),
                label: "Next Worktree",
                chord: GrafttyNavigationShortcuts.nextWorktree,
                source: .fixedWorktree
            ),
            commandCandidate(
                semantic: .navigateWorktree(forward: false),
                label: "Previous Worktree",
                chord: GrafttyNavigationShortcuts.previousWorktree,
                source: .fixedWorktree
            ),
            commandCandidate(
                semantic: .ghostty(.nextTab),
                label: "Next Pane",
                chord: GrafttyNavigationShortcuts.nextPane,
                source: .fixedPane
            ),
            commandCandidate(
                semantic: .ghostty(.previousTab),
                label: "Previous Pane",
                chord: GrafttyNavigationShortcuts.previousPane,
                source: .fixedPane
            ),
        ].compactMap { $0 }

        let hostCandidates: [GrafttyNavigationShortcuts.SourcedCandidate<MobileGhosttyCommandCandidate>]
        if context.keybindingSet.source == .loading {
            hostCandidates = []
        } else {
            hostCandidates = GhosttyCommandRegistry.iPadSupportedActions.compactMap { action in
                guard let entry = GhosttyCommandRegistry[action],
                      entry.kind != .unsupported,
                      isReservableHostAction(action, context: context),
                      let chord = context.keybindingSet.bridge[action] else {
                    return nil
                }
                return commandCandidate(
                    semantic: .ghostty(action),
                    label: entry.label,
                    chord: chord,
                    source: .host
                )
            }
        }

        let sourced = fixedCandidates + hostCandidates
        return GrafttyNavigationShortcuts.collisionWinners(
            from: sourced,
            identifiedBy: { candidate in
                MobileGhosttyCommandChord(
                    input: candidate.input,
                    modifierRawValue: candidate.modifierFlags.rawValue
                )
            }
        ).map(\.value)
    }

    private static func isReservableHostAction(
        _ action: GhosttyAction,
        context: MobileGhosttyCommandContext
    ) -> Bool {
        action == .nextTab || action == .previousTab || context.isEnabled(action)
    }

    private static func commandCandidate(
        semantic: MobileGhosttyCommandSemantic,
        label: String,
        chord: ShortcutChord,
        source: GrafttyNavigationShortcuts.CandidateSource
    ) -> GrafttyNavigationShortcuts.SourcedCandidate<MobileGhosttyCommandCandidate>? {
        guard let shortcut = KeyboardShortcutFromChord.shortcut(from: chord),
              let input = UIKeyCommandInputFromChord.input(from: chord) else {
            return nil
        }
        let candidate = MobileGhosttyCommandCandidate(
            semantic: semantic,
            label: label,
            shortcut: shortcut,
            input: input,
            modifierFlags: UIKeyModifierFlags(chord.modifiers).normalizedAppCommandModifiers
        )
        return GrafttyNavigationShortcuts.SourcedCandidate(source: source, value: candidate)
    }
}

private enum UIKeyCommandInputFromChord {
    static func input(from chord: ShortcutChord) -> String? {
        if chord.key.count == 1 {
            return chord.key
        }
        switch chord.key {
        case "arrowleft":
            return UIKeyCommand.inputLeftArrow
        case "arrowright":
            return UIKeyCommand.inputRightArrow
        case "arrowup":
            return UIKeyCommand.inputUpArrow
        case "arrowdown":
            return UIKeyCommand.inputDownArrow
        case "return":
            return "\r"
        case "tab":
            return "\t"
        case "space":
            return " "
        case "escape":
            return UIKeyCommand.inputEscape
        case "delete":
            return UIKeyCommand.inputDelete
        case "backspace":
            return "\u{8}"
        case "home":
            return UIKeyCommand.inputHome
        case "end":
            return UIKeyCommand.inputEnd
        case "pageup":
            return UIKeyCommand.inputPageUp
        case "pagedown":
            return UIKeyCommand.inputPageDown
        default:
            // Punctuation tokens share ShortcutChord's single table with the
            // SwiftUI translator, so a new token can't silently drop its
            // shortcut on just one dispatch path.
            return ShortcutChord.character(forKeyToken: chord.key).map(String.init)
        }
    }
}

private extension UIKeyModifierFlags {
    var normalizedAppCommandModifiers: UIKeyModifierFlags {
        intersection([.shift, .control, .alternate, .command])
    }

    init(_ modifiers: ShortcutModifiers) {
        self.init()
        if modifiers.contains(.shift) {
            insert(.shift)
        }
        if modifiers.contains(.control) {
            insert(.control)
        }
        if modifiers.contains(.option) {
            insert(.alternate)
        }
        if modifiers.contains(.command) {
            insert(.command)
        }
    }
}
#endif
