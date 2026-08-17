import Foundation
import Testing
import GrafttyKit
@testable import Graftty

@Suite("Native provider plugin launch offer")
struct AgentPluginInstallOfferPolicyTests {
    @Test("""
    @spec AGENT-6.15: When Graftty launches with agent teams enabled and the current bundled provider integration has been neither installed nor acknowledged, the application shall prepare its app-owned snapshots and offer to install both plugins with explicit consent; when the user selects native messaging in Settings, the application shall activate that mode without requiring either provider executable or an installed integration revision; an installation completion shall never overwrite a newer Settings selection, an installation-only completion and an incomplete installation shall otherwise preserve the selected messaging mode, and acknowledging or completing that integration revision shall suppress repeat launch offers while a newer revision may offer again.
    """)
    func launchOfferIsGatedAndVersioned() {
        let revision = AgentPluginInstaller.integrationRevision

        #expect(AgentPluginInstallOfferPolicy.shouldOffer(
            agentTeamsEnabled: true,
            lastAcknowledgedRevision: nil,
            installedRevision: nil
        ))

        #expect(!AgentPluginInstallOfferPolicy.isCurrentIntegrationInstalled(
            installedRevision: revision - 1
        ))
        #expect(AgentPluginInstallOfferPolicy.isCurrentIntegrationInstalled(
            installedRevision: revision
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

        let suite = "AgentPluginSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var refreshCount = 0
        #expect(AgentPluginIntegrationActivation.applyUserSelection(
            enabled: true,
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.object(forKey: SettingsKeys.agentPluginInstalledRevision) == nil)
        #expect(refreshCount == 1)

        // Models accepting the follow-up offer on a machine where neither
        // provider executable exists: the installation is incomplete, but
        // the explicit selection remains active and no revision is recorded.
        #expect(!AgentPluginIntegrationActivation.apply(
            successfulInstallation: false,
            enableNativeMessagingOnSuccess: false,
            userSelectionRevisionAtStart: AgentPluginIntegrationActivation
                .userSelectionRevision(in: defaults),
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.object(forKey: SettingsKeys.agentPluginInstalledRevision) == nil)
        #expect(refreshCount == 2)

        #expect(!AgentPluginIntegrationActivation.applyUserSelection(
            enabled: false,
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(!defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(refreshCount == 3)

        #expect(AgentPluginIntegrationActivation.apply(
            successfulInstallation: true,
            enableNativeMessagingOnSuccess: false,
            userSelectionRevisionAtStart: AgentPluginIntegrationActivation
                .userSelectionRevision(in: defaults),
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(!defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision)
            == AgentPluginInstaller.integrationRevision)
        #expect(refreshCount == 4)
    }

    @Test("A newer Settings selection wins over an older install-and-enable action.")
    func newerUserSelectionWinsOverInstallationCompletion() {
        let suite = "AgentPluginSelectionRace-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let installStartRevision = AgentPluginIntegrationActivation
            .userSelectionRevision(in: defaults)

        _ = AgentPluginIntegrationActivation.applyUserSelection(
            enabled: true,
            defaults: defaults,
            refreshHookAssets: {}
        )
        _ = AgentPluginIntegrationActivation.applyUserSelection(
            enabled: false,
            defaults: defaults,
            refreshHookAssets: {}
        )

        #expect(AgentPluginIntegrationActivation.apply(
            successfulInstallation: true,
            enableNativeMessagingOnSuccess: true,
            userSelectionRevisionAtStart: installStartRevision,
            defaults: defaults,
            refreshHookAssets: {}
        ))
        #expect(!defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision)
            == AgentPluginInstaller.integrationRevision)
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

    @Test("A successful install-and-enable action activates native messaging; a failed installation preserves the prior mode in both directions.")
    func activationPreservesPriorMessagingModeOnFailure() {
        let suite = "AgentPluginIntegrationActivation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var refreshCount = 0

        // Previously-false (legacy mode) stays false after a failed
        // installation, and the installed revision is not recorded.
        defaults.set(false, forKey: SettingsKeys.nativeAgentMessagingEnabled)
        #expect(!AgentPluginIntegrationActivation.apply(
            successfulInstallation: false,
            enableNativeMessagingOnSuccess: true,
            userSelectionRevisionAtStart: AgentPluginIntegrationActivation
                .userSelectionRevision(in: defaults),
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(!defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.object(forKey: SettingsKeys.agentPluginInstalledRevision) == nil)
        #expect(refreshCount == 1)

        // A complete installation activates native messaging and records
        // the installed revision.
        #expect(AgentPluginIntegrationActivation.apply(
            successfulInstallation: true,
            enableNativeMessagingOnSuccess: true,
            userSelectionRevisionAtStart: AgentPluginIntegrationActivation
                .userSelectionRevision(in: defaults),
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision)
            == AgentPluginInstaller.integrationRevision)
        #expect(refreshCount == 2)

        // Previously-true (native mode) stays true when a later
        // (re)installation fails: a revision-bump re-offer that fails must
        // not demote an already-native user to legacy mode while the old
        // plugins remain installed.
        #expect(!AgentPluginIntegrationActivation.apply(
            successfulInstallation: false,
            enableNativeMessagingOnSuccess: true,
            userSelectionRevisionAtStart: AgentPluginIntegrationActivation
                .userSelectionRevision(in: defaults),
            defaults: defaults,
            refreshHookAssets: { refreshCount += 1 }
        ))
        #expect(defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(refreshCount == 3)
    }
}
