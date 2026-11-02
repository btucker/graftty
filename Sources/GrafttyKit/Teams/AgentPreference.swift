import Foundation

/// Host-owned provider choice shared by CLI and UI launch paths.
public enum AgentPreference {
    public static let key = "defaultAgentProvider"

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case noDefault
        public var errorDescription: String? {
            "Choose a default agent in Agent teams settings or pass --provider claude or --provider codex."
        }
    }

    public static func resolve(explicit: TeamHookRuntime?, configured: TeamHookRuntime?) throws -> TeamHookRuntime {
        guard let provider = explicit ?? configured else { throw Error.noDefault }
        return provider
    }

    public static func provider(in defaults: UserDefaults = .standard) -> TeamHookRuntime? {
        defaults.string(forKey: key).flatMap(TeamHookRuntime.init(rawValue:))
    }

    public static func migrate(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil,
              let command = defaults.string(forKey: "defaultCommand")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let provider = TeamHookRuntime(rawValue: command) else { return }
        defaults.set(provider.rawValue, forKey: key)
    }

    public static func needsMigrationChoice(in defaults: UserDefaults = .standard) -> Bool {
        provider(in: defaults) == nil
            && !(defaults.string(forKey: "defaultCommand") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
