import Testing
@testable import GrafttyKit

@Suite("AgentLivenessMerge — isPaneBusy derives a pane's busy state from claude liveness (host-side).")
struct AgentLivenessMergeTests {
    @Test("""
@spec AGENT-2.2: While a pane has no live attention ping, the application shall surface a busy claude session by rendering the pane title in italic (not a capsule), and render the title upright when idle.
""")
    func busyDerivedFromLiveness() {
        #expect(AgentLivenessMerge.isPaneBusy(
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .busy]) == true)
        #expect(AgentLivenessMerge.isPaneBusy(
            sessionName: "graftty-aaaa1111",
            liveness: ["graftty-aaaa1111": .idle]) == false)
    }

    @Test func unknownSessionIsNotBusy() {
        #expect(AgentLivenessMerge.isPaneBusy(sessionName: nil, liveness: [:]) == false)
    }
}
