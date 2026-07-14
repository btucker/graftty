import Foundation

public struct GhosttyKeybindingsResponse: Codable, Sendable, Equatable {
    public let bindings: [String: ShortcutChord]

    public init(bindings: [String: ShortcutChord]) {
        self.bindings = bindings
    }

    public init(chords: [GhosttyAction: ShortcutChord]) {
        self.bindings = Dictionary(uniqueKeysWithValues: chords.map { action, chord in
            (action.rawValue, chord)
        })
    }
}
