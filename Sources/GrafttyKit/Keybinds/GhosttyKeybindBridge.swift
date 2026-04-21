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

    public init(resolver: Resolver) {
        var map: [GhosttyAction: ShortcutChord] = [:]
        for action in GhosttyAction.allCases {
            map[action] = resolver(action.rawValue)
        }
        self.chords = map
    }

    public subscript(action: GhosttyAction) -> ShortcutChord? {
        chords[action]
    }
}
