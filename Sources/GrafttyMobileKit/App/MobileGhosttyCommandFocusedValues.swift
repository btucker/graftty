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
    let action: GhosttyAction
    let label: String
    let shortcut: KeyboardShortcut
}

private struct MobileGhosttyHardwareCommandCandidate {
    let action: GhosttyAction
    let label: String
    let input: String
    let modifierFlags: UIKeyModifierFlags

    var id: String {
        "\(action.rawValue)|\(input)|\(modifierFlags.rawValue)"
    }
}

private struct MobileGhosttyHardwareChord: Hashable {
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
                ForEach(Self.renderableCommands(for: context.keybindingSet), id: \.action) { command in
                    Button(command.label) {
                        context.perform(command.action)
                    }
                    .keyboardShortcut(command.shortcut)
                    .disabled(!context.isEnabled(command.action))
                }
            }
        }
    }

    static func renderableCommands(
        for keybindingSet: MobileGhosttyKeybindingSet
    ) -> [MobileGhosttyCommandDescriptor] {
        GhosttyCommandRegistry.iPadSupportedActions.compactMap { action in
            guard let entry = GhosttyCommandRegistry[action],
                  entry.isSupportedOniPad,
                  entry.kind != .unsupported,
                  let chord = keybindingSet.bridge[action],
                  let shortcut = KeyboardShortcutFromChord.shortcut(from: chord) else {
                return nil
            }
            return MobileGhosttyCommandDescriptor(
                action: action,
                label: entry.label,
                shortcut: shortcut
            )
        }
    }

    static func hardwareKeyboardCommands(
        for context: MobileGhosttyCommandContext
    ) -> [TerminalPaneView.HardwareKeyboardCommand] {
        hardwareKeyboardCommandCandidates(for: context).map { candidate in
            return TerminalPaneView.HardwareKeyboardCommand(
                id: candidate.id,
                title: candidate.label,
                input: candidate.input,
                modifierFlags: candidate.modifierFlags,
                perform: { context.perform(candidate.action) }
            )
        }
    }

    private static func hardwareKeyboardCommandCandidates(
        for context: MobileGhosttyCommandContext
    ) -> [MobileGhosttyHardwareCommandCandidate] {
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

        let primaryCandidates: [MobileGhosttyHardwareCommandCandidate] =
            enabledEntries.compactMap { entry in
                guard let chord = context.keybindingSet.bridge[entry.action] else { return nil }
                return hardwareKeyboardCommandCandidate(entry: entry, chord: chord)
            }
        let aliasCandidates: [MobileGhosttyHardwareCommandCandidate]
        if context.keybindingSet.source == .bundledFallback {
            aliasCandidates = enabledEntries.flatMap { entry in
                GhosttyDefaultKeybinds.aliases[entry.action, default: []].compactMap { chord in
                    hardwareKeyboardCommandCandidate(entry: entry, chord: chord)
                }
            }
        } else {
            aliasCandidates = []
        }

        var seenChords: Set<MobileGhosttyHardwareChord> = []
        return (primaryCandidates + aliasCandidates).filter { candidate in
            seenChords.insert(MobileGhosttyHardwareChord(
                input: candidate.input,
                modifierRawValue: candidate.modifierFlags.rawValue
            )).inserted
        }
    }

    private static func hardwareKeyboardCommandCandidate(
        entry: GhosttyCommandRegistry.Entry,
        chord: ShortcutChord
    ) -> MobileGhosttyHardwareCommandCandidate? {
        guard let input = UIKeyCommandInputFromChord.input(from: chord) else { return nil }
        return MobileGhosttyHardwareCommandCandidate(
            action: entry.action,
            label: entry.label,
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
