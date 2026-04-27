import Testing
import SwiftUI
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test func teamSessionPromptDefaultsToEmpty() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-1")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-1")
        let value = defaults.string(forKey: "teamSessionPrompt") ?? ""
        #expect(value.isEmpty)
    }

    @Test func teamPromptDefaultsToEmpty() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-2")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-2")
        let value = defaults.string(forKey: "teamPrompt") ?? ""
        #expect(value.isEmpty)
    }

    @Test func teamSessionPromptAndTeamPromptAreIndependent() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-3")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-3")
        defaults.set("session", forKey: "teamSessionPrompt")
        defaults.set("event",   forKey: "teamPrompt")
        #expect(defaults.string(forKey: "teamSessionPrompt") == "session")
        #expect(defaults.string(forKey: "teamPrompt") == "event")
    }
}
