import Foundation

/// @spec IPAD-9.8
/// The bundled Ghostty default keybinding table shall mirror the defaults
/// reported by ghostty +list-keybinds --default for every iPad-supported
/// action, leaving new_split:left and new_split:up chordless because
/// Ghostty ships no default binding for them.
///
/// Snapshot of Ghostty's DEFAULT keybindings, used when the host does not
/// serve `GET /ghostty-keybindings` (older host builds return 404) so iPad
/// hardware-keyboard shortcuts still work instead of silently vanishing.
/// Derived by running `ghostty +list-keybinds --default` and transcribing
/// the chords for `GhosttyCommandRegistry.iPadSupportedActions`
/// (Ghostty's `super` maps to `.command`).
public enum GhosttyDefaultKeybinds {
    public static let chords: [GhosttyAction: ShortcutChord] = [
        .newSplitRight: ShortcutChord(key: "d", modifiers: [.command]),
        .newSplitDown: ShortcutChord(key: "d", modifiers: [.command, .shift]),
        .closeSurface: ShortcutChord(key: "w", modifiers: [.command]),
        .gotoSplitLeft: ShortcutChord(key: "arrowleft", modifiers: [.command, .option]),
        .gotoSplitRight: ShortcutChord(key: "arrowright", modifiers: [.command, .option]),
        .gotoSplitUp: ShortcutChord(key: "arrowup", modifiers: [.command, .option]),
        .gotoSplitDown: ShortcutChord(key: "arrowdown", modifiers: [.command, .option]),
        .gotoSplitPrevious: ShortcutChord(key: "bracketleft", modifiers: [.command]),
        .gotoSplitNext: ShortcutChord(key: "bracketright", modifiers: [.command]),
        // Ghostty also binds ctrl+shift+tab / ctrl+tab for tab navigation;
        // Graftty mirrors the super+shift+bracket variants.
        .previousTab: ShortcutChord(key: "bracketleft", modifiers: [.command, .shift]),
        .nextTab: ShortcutChord(key: "bracketright", modifiers: [.command, .shift]),
    ]

    /// A bridge resolving each action to its bundled Ghostty default chord.
    public static let bridge = GhosttyKeybindBridge(chords: chords)
}
