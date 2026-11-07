import Foundation

/// Resolves Ghostty apprt action names to chords. Built once at app
/// launch from `ghostty_config_trigger` via the resolver closure the
/// app target provides.
///
/// Pure value type — no GhosttyKit, no SwiftUI. The app target wraps
/// the raw libghostty call in a closure of shape
/// `(actionName) -> ShortcutChord?` and hands it to the init.
public struct GhosttyKeybindBridge: Sendable {
    /// Resolver isn't `@Sendable` because the app-target adapter needs to
    /// capture a `ghostty_config_t` (an `UnsafeMutableRawPointer`) that
    /// itself isn't Sendable. This is safe: the closure is invoked only
    /// inside `init` (on whatever actor constructed the bridge), never
    /// stored past construction — the struct retains only the resolved
    /// `[GhosttyAction: ShortcutChord]` dictionary, which *is* Sendable.
    public typealias Resolver = (String) -> ShortcutChord?

    private let chords: [GhosttyAction: ShortcutChord]

    /// The native trigger API exposes one resolved trigger per exact action.
    /// Keep history navigation separate from application/menu commands.
    public static let historyActions = ["scroll_to_top", "scroll_page_up", "jump_to_prompt:-1", "scroll_to_selection"]
    public let historyChords: [String: ShortcutChord]
    public var allBindings: [String: ShortcutChord] {
        Dictionary(uniqueKeysWithValues: chords.map { ($0.key.rawValue, $0.value) })
            .merging(historyChords) { _, history in history }
    }

    public var allChords: [GhosttyAction: ShortcutChord] { chords }

    public init(resolver: Resolver) {
        var map: [GhosttyAction: ShortcutChord] = [:]
        for action in GhosttyAction.allCases {
            map[action] = resolver(action.rawValue)
        }
        self.chords = map
        self.historyChords = Dictionary(uniqueKeysWithValues: Self.historyActions.compactMap { action in
            resolver(action).map { (action, $0) }
        })
    }

    /// For callers that already hold resolved chords keyed by action
    /// (decoded host responses, the bundled default table) — skips the
    /// resolver round-trip through raw action names.
    public init(chords: [GhosttyAction: ShortcutChord]) {
        self.chords = chords
        self.historyChords = [:]
    }

    /// The deliberately-shortcutless bridge: "no keybinds", as distinct
    /// from `GhosttyDefaultKeybinds.bridge`'s "fall back to defaults".
    /// Used while host keybindings are being (re)fetched so stale
    /// shortcuts never dispatch against the wrong host.
    public static let empty = GhosttyKeybindBridge(chords: [:])

    public subscript(action: GhosttyAction) -> ShortcutChord? {
        chords[action]
    }
}
