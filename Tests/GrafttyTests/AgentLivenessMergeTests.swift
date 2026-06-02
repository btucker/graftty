import Testing
@testable import GrafttyKit

@Suite("AgentLivenessMerge — pane attention split: effectivePaneText surfaces only the live notify ping; isPaneBusy derives busy from liveness.")
struct AgentLivenessMergeTests {
    @Test("""
@spec AGENT-2.1: While a pane has a live notify attention ping, the application shall render that ping in preference to any derived busy/idle status.
""")
    func notifyPingIsSurfaced() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: "build failed",
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == "build failed")
    }

    @Test("""
@spec AGENT-2.2: While a pane has no live attention ping, the application shall surface a busy claude session by tinting the pane title with the running/active color (not a capsule), and render the title unchanged when idle.
""")
    func busyProducesNoCapsuleTextButIsBusy() {
        let text = AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy])
        #expect(text == nil)
        #expect(AgentLivenessMerge.isPaneBusy(
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy]) == true)
    }

    @Test func idleIsNotBusyAndHasNoText() {
        #expect(AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil,
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .idle]) == nil)
        #expect(AgentLivenessMerge.isPaneBusy(
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .idle]) == false)
    }

    @Test func unknownSessionIsNotBusy() {
        #expect(AgentLivenessMerge.effectivePaneText(
            paneAttentionText: nil, sessionName: nil, liveness: [:]) == nil)
        #expect(AgentLivenessMerge.isPaneBusy(sessionName: nil, liveness: [:]) == false)
    }
}
