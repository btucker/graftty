import Testing
@testable import GrafttyProtocol

@Suite("GhosttyKeybindBridge")
struct GhosttyKeybindBridgeTests {
    @Test("@spec TERM-12.66: When a resolved history navigation shortcut is pressed, the application shall arm on-demand history loading while leaving native key handling intact, and shall publish those resolved shortcuts to paired viewers.")
    func publishesResolvedHistoryChords() {
        let chord = ShortcutChord(key: "h", modifiers: [.command, .shift])
        let bridge = GhosttyKeybindBridge { $0 == "scroll_to_top" ? chord : nil }
        #expect(bridge.historyChords == ["scroll_to_top": chord])
        #expect(GhosttyKeybindingsResponse(bindings: bridge.allBindings).historyChords == [chord])
        #expect(GhosttyKeybindingsResponse(bindings: ["new_tab": chord]).historyChords.isEmpty)
    }

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
        #expect(Set(queried) == Set(GhosttyAction.allCases.map(\.rawValue) + GhosttyKeybindBridge.historyActions))
        #expect(queried.count == GhosttyAction.allCases.count + GhosttyKeybindBridge.historyActions.count,
                "no duplicate queries")
    }

    @Test func unresolvedActionReturnsNil() {
        let bridge = GhosttyKeybindBridge { _ in nil }
        for action in GhosttyAction.allCases {
            #expect(bridge[action] == nil)
        }
    }
}
