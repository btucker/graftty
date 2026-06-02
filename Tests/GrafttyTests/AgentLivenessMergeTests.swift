import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-2.1/2.2: pane attention merge — live notify ping wins; else busy→working…, idle→nil.")
struct AgentLivenessMergeTests {
    @Test func notifyPingWinsOverBusy() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: "build failed",
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == "build failed")
    }

    @Test func busyRendersWorkingWhenNoPing() {
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
