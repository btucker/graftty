import GrafttyCommandUI
import GrafttyProtocol
import Testing

struct AgentStatusBadgeTests {
    @Test("@spec AGENT-2.7: While a running agent's pane has a liveness registry, the application shall spin only for observed busy turns and treat missing entries as idle; without a registry it shall preserve the working spinner for unknown activity.")
    func stoppedTurnStopsSpinning() {
        #expect(!AgentStatusBadge.spins(status: .running, failure: nil, isBusy: false))
        #expect(AgentStatusBadge.spins(status: .running, failure: nil, isBusy: true))
        #expect(AgentStatusBadge.spins(status: .running, failure: nil, isBusy: nil))
        #expect(!AgentStatusBadge.spins(status: .waiting, failure: nil, isBusy: true))
        #expect(!AgentStatusBadge.spins(status: .running, failure: "boom", isBusy: true))
    }

    @Test("@spec AGENT-2.8: While an agent's turn is busy, the application shall show no spinner on its sidebar row, because the agent's terminal title carries its own activity indicator, while agent tabs keep the spinner.")
    func sidebarRowsDropTheSpinner() {
        #expect(!AgentStatusBadge.showsSpinner(status: .running, failure: nil, isBusy: true, placement: .sidebarRow))
        #expect(AgentStatusBadge.showsSpinner(status: .running, failure: nil, isBusy: true, placement: .tab))
    }
}
