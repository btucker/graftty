import Foundation
import Testing
@testable import Graftty

@Suite("FlowState refresh policy")
struct FlowStateRefreshPolicyTests {
    @Test("view open requests refresh when opening auto-starts the agent")
    func viewOpenRefreshesAfterAutoStart() {
        #expect(FlowStateViewOpenRefreshPolicy.shouldRequestRefresh(
            wasRunningBeforeOpen: false,
            isRunningAfterOpen: true
        ))
    }

    @Test("view open does not request refresh when the agent remains stopped")
    func viewOpenDoesNotRefreshWhenStopped() {
        #expect(!FlowStateViewOpenRefreshPolicy.shouldRequestRefresh(
            wasRunningBeforeOpen: false,
            isRunningAfterOpen: false
        ))
    }

    @Test("refresh runtime settings use the configured refresh interval")
    func refreshRuntimeSettingsUseConfiguredInterval() {
        UserDefaults.standard.set(1, forKey: SettingsKeys.flowStateRefreshIntervalMinutes)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.flowStateRefreshIntervalMinutes) }

        #expect(FlowStateRefreshRuntimeSettings.refreshInterval() == 60)
    }
}
