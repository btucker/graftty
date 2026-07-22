import Foundation

/// UserDefaults migrations for renamed team settings and template variables.
/// Idempotent; safe to call on every launch.
///
/// Must run before the first `@AppStorage` read of the new key, so SwiftUI
/// binds to the freshly-migrated value rather than the default.
enum SettingsKeyMigration {
    static let oldKey = "channelRoutingPreferences"
    static let newKey = "teamEventRoutingPreferences"

    static func run(in defaults: UserDefaults = .standard) {
        migrateRoutingPreferences(in: defaults)
        migrateMainWorktreeTemplateVariable(in: defaults, key: SettingsKeys.teamSessionPrompt)
        migrateMainWorktreeTemplateVariable(in: defaults, key: SettingsKeys.teamPrompt)
    }

    private static func migrateRoutingPreferences(in defaults: UserDefaults) {
        // If the new key is already populated, just clean up the old one.
        if defaults.string(forKey: newKey) != nil {
            defaults.removeObject(forKey: oldKey)
            return
        }
        // Copy old → new and clear the old.
        if let old = defaults.string(forKey: oldKey) {
            defaults.set(old, forKey: newKey)
            defaults.removeObject(forKey: oldKey)
        }
    }

    private static func migrateMainWorktreeTemplateVariable(
        in defaults: UserDefaults,
        key: String
    ) {
        guard let template = defaults.string(forKey: key),
              template.contains("agent.lead") else { return }
        defaults.set(
            template.replacingOccurrences(
                of: #"agent\.lead(?![A-Za-z0-9_])"#,
                with: "agent.main_worktree",
                options: .regularExpression
            ),
            forKey: key
        )
    }
}
