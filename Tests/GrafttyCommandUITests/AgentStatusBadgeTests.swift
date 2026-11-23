import GrafttyCommandUI
import GrafttyProtocol
import Testing

struct AgentStatusBadgeTests {
    @Test("@spec AGENT-2.7: While a running agent has a liveness registry, the application shall treat observed busy turns as working and missing entries as idle. Without a registry, unknown activity shall count as working.")
    func workingStateUsesTurnActivity() {
        #expect(!AgentStatusBadge.spins(status: .running, failure: nil, isBusy: false))
        #expect(AgentStatusBadge.spins(status: .running, failure: nil, isBusy: true))
        #expect(AgentStatusBadge.spins(status: .running, failure: nil, isBusy: nil))
        #expect(!AgentStatusBadge.spins(status: .waiting, failure: nil, isBusy: true))
        #expect(!AgentStatusBadge.spins(status: .running, failure: "boom", isBusy: true))
    }

    @Test("@spec AGENT-2.8: While an agent is working, the application shall omit the running status spinner from its tab and sidebar row.")
    func workingTabsAndSidebarRowsOmitTheSpinner() {
        for busy in [true, nil] as [Bool?] {
            #expect(!AgentStatusBadge.showsSpinner(status: .running, failure: nil, isBusy: busy, placement: .sidebarRow))
            #expect(!AgentStatusBadge.showsSpinner(status: .running, failure: nil, isBusy: busy, placement: .tab))
        }
    }

    @Test func overviewCardsShowProgressWhileWorking() {
        for busy in [true, nil] as [Bool?] {
            #expect(AgentStatusBadge.showsSpinner(status: .running, failure: nil, isBusy: busy, placement: .overviewCard))
        }
        #expect(!AgentStatusBadge.showsSpinner(status: .running, failure: nil, isBusy: false, placement: .overviewCard))
    }
}
