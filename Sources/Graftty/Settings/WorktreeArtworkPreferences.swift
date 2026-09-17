import Foundation

enum WorktreeArtworkStyle: String, CaseIterable, Identifiable, Sendable {
    case illustration
    case animation
    case sketch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .illustration: "Illustration"
        case .animation: "Animation"
        case .sketch: "Sketch"
        }
    }
}

struct WorktreeArtworkPreferences {
    static let defaultEnabled = true
    static let defaultStyle = WorktreeArtworkStyle.illustration

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get {
            defaults.object(forKey: SettingsKeys.worktreeArtworkEnabled) == nil
                ? Self.defaultEnabled
                : defaults.bool(forKey: SettingsKeys.worktreeArtworkEnabled)
        }
        nonmutating set {
            defaults.set(newValue, forKey: SettingsKeys.worktreeArtworkEnabled)
        }
    }

    var style: WorktreeArtworkStyle {
        get {
            defaults.string(forKey: SettingsKeys.worktreeArtworkStyle)
                .flatMap(WorktreeArtworkStyle.init(rawValue:)) ?? Self.defaultStyle
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: SettingsKeys.worktreeArtworkStyle)
        }
    }
}
