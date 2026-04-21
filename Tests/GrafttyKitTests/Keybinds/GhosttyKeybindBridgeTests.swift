import Testing
@testable import GrafttyKit

@Suite("GhosttyKeybindBridge")
struct GhosttyKeybindBridgeTests {
    @Test func subscriptReturnsResolvedChord() {
        let bridge = GhosttyKeybindBridge { name in
            name == "new_split:right"
                ? ShortcutChord(key: "d", modifiers: [.command])
                : nil
        }
        #expect(bridge[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))
        #expect(bridge[.closeSurface] == nil)
    }

    @Test func bridgeQueriesEveryActionOnce() {
        var queried: [String] = []
        _ = GhosttyKeybindBridge { name in
            queried.append(name)
            return nil
        }
        #expect(Set(queried) == Set(GhosttyAction.allCases.map(\.rawValue)))
        #expect(queried.count == GhosttyAction.allCases.count,
                "no duplicate queries")
    }

    @Test func unresolvedActionReturnsNil() {
        let bridge = GhosttyKeybindBridge { _ in nil }
        for action in GhosttyAction.allCases {
            #expect(bridge[action] == nil)
        }
    }
}
