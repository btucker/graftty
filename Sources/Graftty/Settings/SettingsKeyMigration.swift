import Foundation

/// One-time UserDefaults migration: copies the legacy
/// `channelRoutingPreferences` value into `teamEventRoutingPreferences`
/// and clears the old key. Idempotent; safe to call on every launch.
///
/// Must run before the first `@AppStorage` read of the new key, so SwiftUI
/// binds to the freshly-migrated value rather than the default.
enum SettingsKeyMigration {
    static let oldKey = "channelRoutingPreferences"
    static let newKey = "teamEventRoutingPreferences"

    static func run(in defaults: UserDefaults = .standard) {
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
}
