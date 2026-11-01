import Foundation
import Testing
@testable import GrafttyKit

struct AgentPreferenceTests {
    @Test("@spec AGENT-6.64: When an agent launch resolves its provider, the application shall prefer an explicit provider over the configured default and require a choice if neither exists.")
    func providerResolution() throws {
        #expect(try AgentPreference.resolve(explicit: .claude, configured: .codex) == .claude)
        #expect(try AgentPreference.resolve(explicit: nil, configured: .codex) == .codex)
        #expect(throws: AgentPreference.Error.noDefault) {
            try AgentPreference.resolve(explicit: nil, configured: nil)
        }
    }

    @Test("@spec AGENT-6.65: When migrating a legacy default command, the application shall recognize a bare Claude or Codex command, retain the original command, and require an explicit choice for commands with custom arguments or shell syntax.")
    func legacyMigration() {
        let name = "AgentPreferenceTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("  claude  ", forKey: "defaultCommand")
        AgentPreference.migrate(in: defaults)
        #expect(AgentPreference.provider(in: defaults) == .claude)
        #expect(defaults.string(forKey: "defaultCommand") == "  claude  ")
        defaults.removeObject(forKey: AgentPreference.key)
        defaults.set("codex --resume", forKey: "defaultCommand")
        AgentPreference.migrate(in: defaults)
        #expect(AgentPreference.provider(in: defaults) == nil)
        #expect(AgentPreference.needsMigrationChoice(in: defaults))
        defaults.set("claude; touch /tmp/unwanted", forKey: "defaultCommand")
        AgentPreference.migrate(in: defaults)
        #expect(AgentPreference.provider(in: defaults) == nil)
        defaults.set("codex", forKey: AgentPreference.key)
        AgentPreference.migrate(in: defaults)
        #expect(AgentPreference.provider(in: defaults) == .codex)
    }
}
