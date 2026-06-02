import Testing
import Foundation
@testable import GrafttyKit

@Suite("AgentStopAttentionTarget — agent-stop attention targets the pane when resolvable, else the worktree.")
struct AgentStopAttentionTargetTests {
    private func entry(slot: PaneSlotID, session: PaneSessionID) -> WorktreeEntry {
        var e = WorktreeEntry(path: "/tmp/wt", branch: "feature")
        e.paneSessions = [slot: session]
        return e
    }

    @Test("""
    @spec AGENT-3.1: When an agent-stop event carries a `paneSessionName` resolving to a live pane, the application shall attach the "needs input" attention to that pane rather than the worktree.
    """)
    func targetsPaneWhenSessionResolves() {
        let slot = PaneSlotID(id: UUID()); let s = PaneSessionID(id: UUID())
        let e = entry(slot: slot, session: s)
        let target = AgentStopAttentionTarget.resolve(
            worktree: e, paneSessionName: ZmxLauncher.sessionName(for: s))
        #expect(target == .pane(slot))
    }

    @Test("""
    @spec AGENT-3.2: If an agent-stop event has no pane session (the agent is not in a Graftty pane), then the application shall fall back to worktree-scoped "needs input" attention.
    """)
    func fallsBackToWorktreeWhenNoSession() {
        let e = entry(slot: PaneSlotID(id: UUID()), session: PaneSessionID(id: UUID()))
        #expect(AgentStopAttentionTarget.resolve(worktree: e, paneSessionName: nil) == .worktree)
        #expect(AgentStopAttentionTarget.resolve(
            worktree: e, paneSessionName: "graftty-nomatch") == .worktree)
    }
}
