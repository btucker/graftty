import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("TerminalManager.evictSurface")
struct TerminalManagerEvictionTests {

    @Test("""
@spec MEM-1.2: When a worktree's surfaces are evicted via the LRU budget, the application shall preserve its zmx sessions, pane-to-session mapping, titles, PWDs, and rehydration state so re-selection re-attaches transparently.
""")
    func evictPreservesMetadata() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
        let sessionID = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)

        manager.recordPaneSession(sessionID, for: terminalID)
        _ = manager.recordTitle("claude", for: terminalID)
        _ = manager.recordPWD("/repo/work", for: terminalID)
        manager.markFirstPane(terminalID)

        manager.evictSurface(terminalID: terminalID)

        // MEM-1.2: titles, PWD, pane→session, first-pane marker all preserved.
        #expect(manager.titles[terminalID] == "claude")
        #expect(manager.pwds[terminalID] == "/repo/work")
        #expect(manager.zmxSessionName(for: terminalID) != nil)
        #expect(manager.isFirstPane(terminalID))
        // MEM-1.2: rehydration is marked so re-create skips default-command injection.
        #expect(manager.wasRehydrated(terminalID))
    }

    @Test("""
@spec MEM-1.5: When the LRU budget evicts a worktree, the application shall not kill its zmx sessions or fire `paneClosed` callbacks.
""")
    func evictDoesNotFirePaneClosed() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
        let sessionID = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)
        manager.recordPaneSession(sessionID, for: terminalID)

        var paneClosedCalls: [(PaneSlotID, String?)] = []
        manager.paneClosed = { id, name in paneClosedCalls.append((id, name)) }

        manager.evictSurface(terminalID: terminalID)

        #expect(paneClosedCalls.isEmpty)
    }

    @Test func evictWithoutSurfaceStillMarksRehydrated() {
        // Defensive: if the budget asks to evict a leaf that never had a
        // surface materialized (e.g. it lived in an unselected worktree),
        // the rehydration flag still gets set so a future surface creation
        // takes the zmx-attach path.
        let manager = TerminalManager(socketPath: "/tmp/graftty-evict-test.sock")
        let terminalID = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!)
        #expect(!manager.wasRehydrated(terminalID))
        manager.evictSurface(terminalID: terminalID)
        #expect(manager.wasRehydrated(terminalID))
    }
}
