import Testing
import Foundation
@testable import Graftty

@Suite("@spec TEAM-1.10: When the application starts, the application shall migrate any legacy `channelRoutingPreferences` UserDefaults string into `teamEventRoutingPreferences` and clear the old key. The migration is idempotent: if `teamEventRoutingPreferences` is already populated, the migration leaves the new value alone and only clears the old key. If neither key is present the migration is a no-op.")
struct SettingsKeyMigrationTests {

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
}
