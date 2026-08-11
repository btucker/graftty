import Foundation
import Testing
import GrafttyKit
@testable import Graftty

@Suite("Native provider plugin launch offer")
struct AgentPluginInstallOfferPolicyTests {
    @Test("""
    @spec AGENT-6.15: When Graftty launches with agent teams enabled and the current bundled provider integration has been neither installed nor acknowledged, the application shall prepare its app-owned snapshots and offer to install both plugins with explicit consent; a complete installation shall enable native messaging, an incomplete installation shall preserve legacy mode, and acknowledging or completing that integration revision shall suppress repeat launch offers while a newer revision may offer again.
    """)
    func launchOfferIsGatedAndVersioned() {
        let revision = AgentPluginInstaller.integrationRevision

        #expect(AgentPluginInstallOfferPolicy.shouldOffer(
            agentTeamsEnabled: true,
            lastAcknowledgedRevision: nil,
            installedRevision: nil
        ))
        #expect(!AgentPluginInstallOfferPolicy.shouldOffer(
            agentTeamsEnabled: false,
            lastAcknowledgedRevision: nil,
            installedRevision: nil
        ))
        #expect(!AgentPluginInstallOfferPolicy.shouldOffer(
            agentTeamsEnabled: true,
            lastAcknowledgedRevision: revision,
            installedRevision: nil
        ))
        #expect(!AgentPluginInstallOfferPolicy.shouldOffer(
            agentTeamsEnabled: true,
            lastAcknowledgedRevision: nil,
            installedRevision: revision
        ))
        #expect(AgentPluginInstallOfferPolicy.shouldOffer(
            agentTeamsEnabled: true,
            lastAcknowledgedRevision: revision - 1,
            installedRevision: revision - 1
        ))
    }

    @Test("Acknowledgement and successful installation persist independently.")
    func recordsOfferLifecycle() {
        let suite = "AgentPluginInstallOfferPolicy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstallOfferRevision)
            == AgentPluginInstaller.integrationRevision)
        #expect(defaults.object(forKey: SettingsKeys.agentPluginInstalledRevision) == nil)

        AgentPluginInstallOfferPolicy.recordInstalled(in: defaults)
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision)
            == AgentPluginInstaller.integrationRevision)
    }

    @Test("Only a complete provider installation activates native messaging.")
    func activationPreservesLegacyModeOnPartialFailure() {
        let suite = "AgentPluginIntegrationActivation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var refreshCount = 0
        defaults.set(true, forKey: SettingsKeys.nativeAgentMessagingEnabled)

        #expect(!AgentPluginIntegrationActivation.apply(
            successfulInstallation: false,
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(!defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(refreshCount == 1)

        #expect(AgentPluginIntegrationActivation.apply(
            successfulInstallation: true,
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision)
            == AgentPluginInstaller.integrationRevision)
        #expect(refreshCount == 2)
    }
}
