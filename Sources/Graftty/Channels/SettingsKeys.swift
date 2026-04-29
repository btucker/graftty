import Foundation

/// Centralized UserDefaults key strings used across Settings panes and observers.
enum SettingsKeys {
    static let agentTeamsEnabled         = "agentTeamsEnabled"
    static let channelsEnabled           = "channelsEnabled"
    static let channelRoutingPreferences = "channelRoutingPreferences"
    static let teamSessionPrompt         = "teamSessionPrompt"
    static let teamPrompt                = "teamPrompt"
    static let defaultCommand            = "defaultCommand"
    static let editorKind                = "editorKind"          // "" | "app" | "cli"
    static let editorAppBundleID         = "editorAppBundleID"
    static let editorCliCommand          = "editorCliCommand"
}
