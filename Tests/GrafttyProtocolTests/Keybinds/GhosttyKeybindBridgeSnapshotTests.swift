import Testing
@testable import GrafttyProtocol

@Suite("GhosttyKeybindBridge snapshots")
struct GhosttyKeybindBridgeSnapshotTests {
    @Test func allChordsReturnsResolvedActionSnapshot() {
        let chord = ShortcutChord(key: "d", modifiers: [.command])
        let bridge = GhosttyKeybindBridge { name in
            name == GhosttyAction.newSplitRight.rawValue ? chord : nil
        }

        #expect(bridge.allChords == [.newSplitRight: chord])
    }
}
