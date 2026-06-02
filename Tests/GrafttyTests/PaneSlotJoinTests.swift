import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec AGENT-1.3: paneSlot(forSessionName:) resolves a zmx session name to its pane slot or nil when unmatched.")
struct PaneSlotJoinTests {
    private func entry(with sessions: [PaneSlotID: PaneSessionID]) -> WorktreeEntry {
        var e = WorktreeEntry(path: "/tmp/wt", branch: "feature")
        e.paneSessions = sessions
        return e
    }

    @Test func resolvesMatchingSession() {
        let slot = PaneSlotID(id: UUID())
        let paneSession = PaneSessionID(id: UUID())
        let e = entry(with: [slot: paneSession])
        #expect(e.paneSlot(forSessionName: ZmxLauncher.sessionName(for: paneSession)) == slot)
    }

    @Test func returnsNilForUnknownSession() {
        let e = entry(with: [PaneSlotID(id: UUID()): PaneSessionID(id: UUID())])
        #expect(e.paneSlot(forSessionName: "graftty-deadbeef") == nil)
    }
}
