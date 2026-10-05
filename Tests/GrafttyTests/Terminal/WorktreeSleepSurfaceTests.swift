import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
struct WorktreeSleepSurfaceTests {
    @Test("@spec SLEEP-15: When automatic sleep evicts a pane's renderer, the application shall preserve its zmx session mapping, title, shell readiness, and existing Stop behavior.")
    func sleepingRendererKeepsSession() {
        let tm = TerminalManager(socketPath: "/tmp/graftty-sleep-surface-test.sock")
        let slot = PaneSlotID()
        let session = PaneSessionID()
        tm.recordPaneSession(session, for: slot, worktreePath: "/isolated-test")
        _ = tm.recordTitle("Existing title", for: slot)
        tm.shellBecameReady(for: slot)
        let original = tm.zmxSessionName(for: slot)
        tm.evictSurface(terminalID: slot)
        #expect(tm.zmxSessionName(for: slot) == original)
        #expect(tm.titles[slot] == "Existing title")
        #expect(tm.isShellReady(slot))
        #expect(tm.wasRehydrated(slot))
        tm.destroySurface(terminalID: slot)
        #expect(tm.zmxSessionName(for: slot) == nil)
        #expect(!tm.isShellReady(slot))
    }
}
