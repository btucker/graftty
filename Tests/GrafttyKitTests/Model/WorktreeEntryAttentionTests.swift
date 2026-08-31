import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("WorktreeEntry attention API")
struct WorktreeEntryAttentionTests {
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

    @Test("""
    @spec AGENT-3.7: While provider-owned needs-input attention remains unacknowledged at a pane or worktree target, repeated or overlapping provider signals shall not replace that attention or post another desktop notification.
    """)
    func repeatedProviderAttentionIsDeduplicated() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        let slot = PaneSlotID(id: UUID())
        let first = Attention(
            text: "Claude has a question",
            timestamp: Date(timeIntervalSince1970: 1),
            source: .agentStop
        )
        let duplicate = Attention(
            text: "Claude needs permission",
            timestamp: Date(timeIntervalSince1970: 2),
            source: .agentStop
        )

        let recordedFirst = e.setAgentStopAttentionIfAbsent(first, pane: slot)
        let recordedDuplicate = e.setAgentStopAttentionIfAbsent(duplicate, pane: slot)

        #expect(recordedFirst)
        #expect(!recordedDuplicate)
        #expect(e.paneAttention[slot] == first)
    }

    @Test func acknowledgePaneClearsOnlyThatPane() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        let focused = PaneSlotID(id: UUID())
        let other = PaneSlotID(id: UUID())
        e.attention = att("w", .userNotify)
        e.paneAttention[focused] = att("needs input", .agentStop)
        e.paneAttention[other] = att("needs input", .agentStop)
        e.acknowledgePaneAttention(focused)
        #expect(e.paneAttention[focused] == nil)   // focused pane cleared
        #expect(e.paneAttention[other] != nil)      // sibling pane untouched
        #expect(e.attention != nil)                 // worktree-scoped untouched
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
    @spec AGENT-3.4: When a provider reports SessionStart, PostToolUse, or Stop after an explicit attention request, the application shall clear provider-owned attention at that hook's pane or worktree target while preserving user notifications and command-finished markers.
    """)
    func providerProgressClearsOnlyTargetedAgentAttention() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        let target = PaneSlotID(id: UUID())
        let notify = PaneSlotID(id: UUID())
        let sibling = PaneSlotID(id: UUID())
        e.paneAttention[target] = att("needs input", .agentStop)
        e.paneAttention[notify] = att("user ping", .userNotify)
        e.paneAttention[sibling] = att("needs input", .agentStop)

        e.clearAgentStopAttention(pane: target)
        e.clearAgentStopAttention(pane: notify)

        #expect(e.paneAttention[target] == nil)
        #expect(e.paneAttention[notify] != nil)
        #expect(e.paneAttention[sibling] != nil)
    }

    @Test func providerProgressClearsWorktreeScopedAgentAttention() {
        var e = WorktreeEntry(path: "/wt", branch: "f")
        e.attention = att("needs input", .agentStop)
        e.clearAgentStopAttention(pane: nil)
        #expect(e.attention == nil)
    }
}
