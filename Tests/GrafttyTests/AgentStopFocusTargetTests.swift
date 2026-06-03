import Testing
import Foundation
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@Suite("Agent-stop notification activation focuses the pane that produced it.")
struct AgentStopFocusTargetTests {
    @Test("""
    @spec AGENT-3.3: When the user activates an agent-stop desktop notification, the application shall focus the pane whose session produced it, falling back to the worktree's first pane when the session no longer resolves.
    """)
    func focusesTriggeringPaneElseFirst() {
        let firstSlot = PaneSlotID(id: UUID())
        let agentSlot = PaneSlotID(id: UUID())
        let agentSession = PaneSessionID(id: UUID())
        var wt = WorktreeEntry(path: "/tmp/wt", branch: "feature")
        wt.paneSessions = [agentSlot: agentSession]
        // Drives the firstPane fallback (firstPane = focusedPaneSlotID ?? first leaf).
        wt.focusedPaneSlotID = firstSlot

        // The triggering pane resolves → focus THAT pane, not the first one.
        #expect(GrafttyApp.agentStopFocusTarget(
            worktree: wt,
            paneSessionName: ZmxLauncher.sessionName(for: agentSession)) == agentSlot)

        // No pane session, or one that no longer resolves → fall back to firstPane.
        #expect(GrafttyApp.agentStopFocusTarget(
            worktree: wt, paneSessionName: nil) == firstSlot)
        #expect(GrafttyApp.agentStopFocusTarget(
            worktree: wt, paneSessionName: "graftty-nomatch") == firstSlot)
    }
}
