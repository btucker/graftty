import Testing
@testable import GrafttyKit

@Suite("AgentLivenessMerge — pane attention merge: live notify ping wins; else busy→working…, idle→nil.")
struct AgentLivenessMergeTests {
    @Test("""
@spec AGENT-2.1: While a pane has a live notify attention ping, the application shall render that ping in preference to any derived busy/idle status.
""")
    func notifyPingWinsOverBusy() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: "build failed",
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == "build failed")
    }

    @Test("""
@spec AGENT-2.2: While a pane has no live attention ping, the application shall render `working…` when its claude session is busy and render nothing when it is idle.
""")
    func busyRendersWorkingWhenNoPing() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == "working…")
    }

    @Test func idleRendersNothing() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .idle])
        #expect(text == nil)
    }

    @Test func unknownSessionRendersNothing() {
        #expect(AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil, sessionName: nil, liveness: [:]) == nil)
    }
}
