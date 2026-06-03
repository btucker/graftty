import Foundation
import Testing
@testable import GrafttyKit

@Suite("WorktreeEntry attention API — single place to set, acknowledge, and resume-clear.")
struct WorktreeEntryAttentionTests {
    private func name(_ s: PaneSessionID) -> String { ZmxLauncher.sessionName(for: s) }
    private func att(_ text: String, _ source: AttentionSource) -> Attention {
        Attention(text: text, timestamp: Date(timeIntervalSince1970: 1), source: source)
    }

    @Test func setAttentionScopesByPaneOrWorktree() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        let slot = PaneSlotID(id: UUID())
        let pane = att("p", .agentStop)
        e.setAttention(pane, pane: slot)
        #expect(e.paneAttention[slot] == pane)
        let wt = att("w", .userNotify)
        e.setAttention(wt, pane: nil)
        #expect(e.attention == wt)
    }

    @Test func acknowledgeClearsWorktreeAndAllPanes() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        let slot = PaneSlotID(id: UUID())
        e.attention = att("w", .userNotify)
        e.paneAttention[slot] = att("p", .agentStop)
        e.acknowledgeAttention()
        #expect(e.attention == nil)
        #expect(e.paneAttention.isEmpty)
    }

    @Test("""
    @spec AGENT-3.4: When a pane's agent transitions to busy, the application shall clear that pane's agent-stop "needs input" attention (leaving user notify pings and command-finished markers), so busy and needs-input are mutually exclusive.
    """)
    func resumeClearsOnlyAgentStopForBusyPanes() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        let busy = PaneSlotID(id: UUID()); let busyS = PaneSessionID(id: UUID())
        let notify = PaneSlotID(id: UUID()); let notifyS = PaneSessionID(id: UUID())
        let idle = PaneSlotID(id: UUID()); let idleS = PaneSessionID(id: UUID())
        e.paneSessions = [busy: busyS, notify: notifyS, idle: idleS]
        e.paneAttention[busy] = att("needs input", .agentStop)
        e.paneAttention[notify] = att("user ping", .userNotify)
        e.paneAttention[idle] = att("needs input", .agentStop)

        e.clearAgentStopAttention(forBusySessionNames: [name(busyS), name(notifyS)])

        #expect(e.paneAttention[busy] == nil)       // agent-stop + busy → cleared
        #expect(e.paneAttention[notify] != nil)     // busy but user ping → kept
        #expect(e.paneAttention[idle] != nil)       // agent-stop but not busy → kept
    }

    @Test func resumeClearsWorktreeScopedAgentStopWhenASessionIsBusy() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        let slot = PaneSlotID(id: UUID()); let s = PaneSessionID(id: UUID())
        e.paneSessions = [slot: s]
        e.attention = att("needs input", .agentStop)
        e.clearAgentStopAttention(forBusySessionNames: [name(s)])
        #expect(e.attention == nil)
    }
}
