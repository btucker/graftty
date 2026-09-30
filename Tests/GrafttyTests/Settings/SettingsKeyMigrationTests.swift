import Testing
import Foundation
@testable import Graftty

@Suite("@spec TEAM-1.10: When the application starts, the application shall migrate any legacy `channelRoutingPreferences` UserDefaults string into `teamEventRoutingPreferences` and clear the old key. The migration is idempotent: if `teamEventRoutingPreferences` is already populated, the migration leaves the new value alone and only clears the old key. If neither key is present the migration is a no-op.")
struct SettingsKeyMigrationTests {

    @Test("@spec TEAM-1.1: When Graftty starts, the application shall make Agent Teams available without an enable switch, including for users who previously disabled them.")
    func removesLegacyAgentTeamsOptOut() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SettingsKeys.agentTeamsEnabled)

        SettingsKeyMigration.run(in: defaults)
        defaults.register(defaults: [SettingsKeys.agentTeamsEnabled: true])

        #expect(defaults.bool(forKey: SettingsKeys.agentTeamsEnabled))
        #expect(defaults.persistentDomain(forName: suiteName)?[SettingsKeys.agentTeamsEnabled] == nil)
    }

    @Test func migratesOldKeyToNew() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("{\"prMerged\":1}", forKey: "channelRoutingPreferences")

        SettingsKeyMigration.run(in: defaults)

        #expect(defaults.string(forKey: "channelRoutingPreferences") == nil)
        #expect(defaults.string(forKey: "teamEventRoutingPreferences") == "{\"prMerged\":1}")
    }

    @Test func doesNotOverwriteExistingNewKey() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("{\"prMerged\":1}", forKey: "channelRoutingPreferences")
        defaults.set("{\"prMerged\":2}", forKey: "teamEventRoutingPreferences")

        SettingsKeyMigration.run(in: defaults)

        #expect(defaults.string(forKey: "teamEventRoutingPreferences") == "{\"prMerged\":2}")
        #expect(defaults.string(forKey: "channelRoutingPreferences") == nil)
    }

    @Test func noOpWhenNoOldKey() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!

        SettingsKeyMigration.run(in: defaults)

        #expect(defaults.string(forKey: "channelRoutingPreferences") == nil)
        #expect(defaults.string(forKey: "teamEventRoutingPreferences") == nil)
    }

    @Test("@spec TEAM-1.12: On startup, the application shall migrate `agent.lead` references in the saved team event prompt template to `agent.main_worktree` before any AppStorage binding reads it.")
    func migratesLegacyTemplateVocabulary() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("{{ agent.lead }} / {{ agent.this_worktree }}", forKey: "teamPrompt")

        SettingsKeyMigration.run(in: defaults)

        #expect(defaults.string(forKey: "teamPrompt") == "{{ agent.main_worktree }} / {{ agent.this_worktree }}")
    }

    @Test func leavesLongerTemplateIdentifiersUnchanged() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Follow agent.leadership guidance", forKey: "teamPrompt")

        SettingsKeyMigration.run(in: defaults)

        #expect(defaults.string(forKey: "teamPrompt") == "Follow agent.leadership guidance")
    }
}
