#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

struct MobileGhosttyCommandContext {
    let keybindBridge: GhosttyKeybindBridge
    let perform: (GhosttyAction) -> Void
    let isEnabled: (GhosttyAction) -> Bool
}

struct MobileGhosttyCommandDescriptor {
    let action: GhosttyAction
    let label: String
    let shortcut: KeyboardShortcut
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
                ForEach(Self.renderableCommands(for: context.keybindBridge), id: \.action) { command in
                    Button(command.label) {
                        context.perform(command.action)
                    }
                    .keyboardShortcut(command.shortcut)
                    .disabled(!context.isEnabled(command.action))
                }
            }
        }
    }

    static func renderableCommands(for bridge: GhosttyKeybindBridge) -> [MobileGhosttyCommandDescriptor] {
        GhosttyCommandRegistry.iPadSupportedActions.compactMap { action in
            guard let entry = GhosttyCommandRegistry[action],
                  entry.isSupportedOniPad,
                  entry.kind != .unsupported,
                  let chord = bridge[action],
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
}
#endif
