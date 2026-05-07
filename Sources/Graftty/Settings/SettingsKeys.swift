import Foundation
import GrafttyKit

/// Centralized UserDefaults key strings used across Settings panes and observers.
enum SettingsKeys {
    static let agentTeamsEnabled         = "agentTeamsEnabled"
    static let channelsEnabled           = "channelsEnabled"
    static let teamEventRoutingPreferences = "teamEventRoutingPreferences"
    static let teamSessionPrompt         = "teamSessionPrompt"
    static let teamPrompt                = "teamPrompt"
    static let defaultCommand            = "defaultCommand"
    // Editor keys are owned by GrafttyKit (so the resolver and the UI never drift).
    static let editorKind                = EditorPreference.Keys.kind
    static let editorAppBundleID         = EditorPreference.Keys.appBundleID
    static let editorCliCommand          = EditorPreference.Keys.cliCommand
}
