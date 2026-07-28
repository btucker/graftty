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

    @Test("@spec TEAM-1.12: On startup, the application shall migrate `agent.lead` references in saved team session and event prompt templates to `agent.main_worktree` before any AppStorage binding reads them.")
    func migratesLegacyTemplateVocabulary() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("{% if agent.lead %}main{% endif %}", forKey: "teamSessionPrompt")
        defaults.set("{{ agent.lead }} / {{ agent.this_worktree }}", forKey: "teamPrompt")

        SettingsKeyMigration.run(in: defaults)

        let session = defaults.string(forKey: "teamSessionPrompt")
        #expect(session?.hasPrefix(DefaultPrompts.sessionPrompt) == true)
        #expect(session?.hasSuffix("{% if agent.main_worktree %}main{% endif %}") == true)
        #expect(defaults.string(forKey: "teamPrompt") == "{{ agent.main_worktree }} / {{ agent.this_worktree }}")
    }

    @Test func leavesLongerTemplateIdentifiersUnchanged() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("Follow agent.leadership guidance", forKey: "teamSessionPrompt")

        SettingsKeyMigration.run(in: defaults)

        let migrated = defaults.string(forKey: "teamSessionPrompt")
        #expect(migrated?.hasPrefix(DefaultPrompts.sessionPrompt) == true)
        #expect(migrated?.hasSuffix("Follow agent.leadership guidance") == true)
    }

    @Test func migratesLegacySessionSuffixIntoTheCompleteVisibleTemplateOnce() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(
            "My custom coordination policy.",
            forKey: SettingsKeys.teamSessionPrompt
        )

        SettingsKeyMigration.run(in: defaults)
        let first = defaults.string(forKey: SettingsKeys.teamSessionPrompt)
        SettingsKeyMigration.run(in: defaults)

        #expect(first?.hasPrefix(DefaultPrompts.sessionPrompt) == true)
        #expect(first?.hasSuffix("My custom coordination policy.") == true)
        #expect(defaults.string(forKey: SettingsKeys.teamSessionPrompt) == first)
    }

    @Test func legacyEmptySessionSuffixRevealsTheCompleteRegisteredDefault() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("", forKey: SettingsKeys.teamSessionPrompt)

        SettingsKeyMigration.run(in: defaults)
        defaults.register(defaults: DefaultPrompts.registrations)

        #expect(
            defaults.string(forKey: SettingsKeys.teamSessionPrompt) ==
            DefaultPrompts.sessionPrompt
        )
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        #expect(persisted[SettingsKeys.teamSessionPrompt] == nil)
    }

    @Test func legacySuffixMentioningTheNewHeaderStillMigrates() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        let suffix = "Do not repeat “Graftty team context.”"
        defaults.set(suffix, forKey: SettingsKeys.teamSessionPrompt)

        SettingsKeyMigration.run(in: defaults)

        let migrated = defaults.string(forKey: SettingsKeys.teamSessionPrompt)
        #expect(migrated?.hasPrefix(DefaultPrompts.sessionPrompt) == true)
        #expect(migrated?.hasSuffix(suffix) == true)
        #expect(migrated != suffix)
    }

    @Test func invalidLegacySessionSuffixCannotDisableTheBuiltInContext() {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        let invalidSuffix = "{% if %}"
        defaults.set(invalidSuffix, forKey: SettingsKeys.teamSessionPrompt)

        SettingsKeyMigration.run(in: defaults)
        defaults.register(defaults: DefaultPrompts.registrations)

        #expect(
            defaults.string(forKey: SettingsKeys.teamSessionPrompt) ==
            DefaultPrompts.sessionPrompt
        )
        #expect(
            defaults.string(
                forKey: SettingsKeys.teamSessionPromptLegacySuffixBackup
            ) == invalidSuffix
        )
    }

    @Test func contextDependentLegacyFailuresCannotDisableAnyViewerContext() {
        let invalidSuffixes = [
            """
            {% if agent.main_worktree %}main-only{% else %}
            {% include "missing-linked-template" %}
            {% endif %}
            """,
            """
            {% for peer in team.other_worktrees %}
            {% include "missing-peer-template" %}
            {% endfor %}
            """,
            """
            {% for peer in team.other_worktrees %}peer
            {% empty %}{% include "missing-empty-roster-template" %}
            {% endfor %}
            """,
        ]

        for invalidSuffix in invalidSuffixes {
            let suiteName = "test-\(UUID())"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(invalidSuffix, forKey: SettingsKeys.teamSessionPrompt)

            SettingsKeyMigration.run(in: defaults)
            defaults.register(defaults: DefaultPrompts.registrations)

            #expect(
                defaults.string(forKey: SettingsKeys.teamSessionPrompt) ==
                DefaultPrompts.sessionPrompt
            )
            #expect(
                defaults.string(
                    forKey: SettingsKeys.teamSessionPromptLegacySuffixBackup
                ) == invalidSuffix
            )
        }
    }
}
