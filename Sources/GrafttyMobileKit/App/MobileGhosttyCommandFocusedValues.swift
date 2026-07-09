#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

struct MobileGhosttyCommandContext {
    let keybindingSet: MobileGhosttyKeybindingSet
    let perform: (GhosttyAction) -> Void
    let isEnabled: (GhosttyAction) -> Bool
}

struct MobileGhosttyCommandDescriptor {
    let id: String
    let action: GhosttyAction
    let label: String
    let shortcut: KeyboardShortcut
    let input: String
    let modifierFlags: UIKeyModifierFlags
}

private struct MobileGhosttyCommandCandidate {
    let action: GhosttyAction
    let label: String
    let shortcut: KeyboardShortcut
    let input: String
    let modifierFlags: UIKeyModifierFlags

    var id: String {
        "\(action.rawValue)|\(input)|\(modifierFlags.rawValue)"
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
                        context.perform(command.action)
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
                action: candidate.action,
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
                perform: { context.perform(candidate.action) }
            )
        }
    }

    private static func commandCandidates(
        for context: MobileGhosttyCommandContext
    ) -> [MobileGhosttyCommandCandidate] {
        guard context.keybindingSet.source != .loading else { return [] }

        let enabledEntries: [GhosttyCommandRegistry.Entry] =
            GhosttyCommandRegistry.iPadSupportedActions.compactMap { action in
                guard context.isEnabled(action),
                      let entry = GhosttyCommandRegistry[action],
                      entry.isSupportedOniPad,
                      entry.kind != .unsupported else {
                    return nil
                }
                return entry
            }

        let primaryCandidates: [MobileGhosttyCommandCandidate] =
            enabledEntries.compactMap { entry in
                guard let chord = context.keybindingSet.bridge[entry.action] else { return nil }
                return commandCandidate(entry: entry, chord: chord)
            }
        let aliasCandidates: [MobileGhosttyCommandCandidate]
        if context.keybindingSet.source == .bundledFallback {
            aliasCandidates = enabledEntries.flatMap { entry in
                GhosttyDefaultKeybinds.aliases[entry.action, default: []].compactMap { chord in
                    commandCandidate(entry: entry, chord: chord)
                }
            }
        } else {
            aliasCandidates = []
        }

        var seenChords: Set<MobileGhosttyCommandChord> = []
        return (primaryCandidates + aliasCandidates).filter { candidate in
            seenChords.insert(MobileGhosttyCommandChord(
                input: candidate.input,
                modifierRawValue: candidate.modifierFlags.rawValue
            )).inserted
        }
    }

    private static func commandCandidate(
        entry: GhosttyCommandRegistry.Entry,
        chord: ShortcutChord
    ) -> MobileGhosttyCommandCandidate? {
        guard let shortcut = KeyboardShortcutFromChord.shortcut(from: chord),
              let input = UIKeyCommandInputFromChord.input(from: chord) else {
            return nil
        }
        return MobileGhosttyCommandCandidate(
            action: entry.action,
            label: entry.label,
            shortcut: shortcut,
            input: input,
            modifierFlags: UIKeyModifierFlags(chord.modifiers).normalizedAppCommandModifiers
        )
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
        case "comma":
            return ","
        case "minus":
            return "-"
        case "period":
            return "."
        case "slash":
            return "/"
        case "semicolon":
            return ";"
        case "equal":
            return "="
        case "quote":
            return "'"
        case "bracketleft":
            return "["
        case "backslash":
            return "\\"
        case "bracketright":
            return "]"
        case "backquote":
            return "`"
        default:
            return nil
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
