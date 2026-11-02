import GrafttyCommandUI
import GrafttyProtocol
import Testing

struct AgentStatusBadgeTests {
    @Test("@spec AGENT-2.7: While a running agent's pane reports its turn as stopped, the application shall show the agent as idle instead of a working spinner, and shall keep the spinner while the turn is busy or its activity is unknown.")
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
