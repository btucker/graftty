import Testing
import SwiftUI
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test func enablingTeamsTurnsOnChannels() {
        let defaults = UserDefaults(suiteName: "AgentTeamsSettingsPaneTests-1")!
        defaults.removePersistentDomain(forName: "AgentTeamsSettingsPaneTests-1")
        defaults.set(false, forKey: "channelsEnabled")
        defaults.set(false, forKey: "agentTeamsEnabled")

        AgentTeamsSettingsPane.applyTeamModeToggleSideEffects(
            newValue: true,
            defaults: defaults
        )

        #expect(defaults.bool(forKey: "channelsEnabled") == true)
    }

    @Test func disablingChannelsAlsoDisablesTeamMode() {
        let defaults = UserDefaults(suiteName: "AgentTeamsSettingsPaneTests-2")!
        defaults.removePersistentDomain(forName: "AgentTeamsSettingsPaneTests-2")
        defaults.set(true, forKey: "channelsEnabled")
        defaults.set(true, forKey: "agentTeamsEnabled")

        AgentTeamsSettingsPane.applyChannelsToggleSideEffects(
            newValue: false,
            defaults: defaults
        )

        #expect(defaults.bool(forKey: "agentTeamsEnabled") == false)
    }
}
