import Foundation
import Testing
@testable import Graftty

@Suite("Worktree artwork preferences")
struct WorktreeArtworkPreferencesTests {
    @Test("@spec SETTINGS-1.1: When worktree artwork preferences have not been saved, the application shall enable worktree backgrounds and use Illustration; an unrecognized saved style shall fall back to Illustration.")
    func defaultsAndUnknownStyle() throws {
        let suiteName = "WorktreeArtworkPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WorktreeArtworkPreferences(defaults: defaults)

        #expect(preferences.isEnabled)
        #expect(preferences.style == .illustration)
        defaults.set("unknown-style", forKey: SettingsKeys.worktreeArtworkStyle)
        #expect(preferences.style == .illustration)
    }

    @Test("@spec SETTINGS-1.2: When the user changes worktree artwork preferences, the application shall persist the enabled state and chosen Atlas, Bold, or Linework style independently so disabling artwork preserves the style.")
    func persistsSelectionAcrossEnableChanges() throws {
        let suiteName = "WorktreeArtworkPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WorktreeArtworkPreferences(defaults: defaults)

        #expect(WorktreeArtworkStyle.allCases.map(\.rawValue) == ["illustration", "animation", "sketch"])
        #expect(WorktreeArtworkStyle.allCases.map(\.svgLabel) == ["Atlas", "Bold", "Linework"])
        for style in WorktreeArtworkStyle.allCases {
            preferences.style = style
            preferences.isEnabled = false
            let reloaded = WorktreeArtworkPreferences(defaults: defaults)
            #expect(!reloaded.isEnabled)
            #expect(reloaded.style == style)
            #expect(defaults.string(forKey: SettingsKeys.worktreeArtworkStyle) == style.rawValue)
            reloaded.isEnabled = true
            #expect(reloaded.isEnabled)
            #expect(reloaded.style == style)
        }
    }
}
