import Foundation
import Testing
import GrafttyKit
@testable import Graftty

@Suite("Native provider plugin launch offer")
struct AgentPluginInstallOfferPolicyTests {
    @Test("""
    @spec AGENT-6.15: When Graftty launches with no previously completed provider installation and an unacknowledged integration revision, the application shall offer to install both plugins with explicit consent; a complete installation shall record the installed integration revision, and an incomplete installation shall record nothing so the offer and the Settings warning persist.
    """)
    func launchOfferIsGatedAndVersioned() {
        let revision = AgentPluginInstaller.integrationRevision

        #expect(AgentPluginInstallOfferPolicy.shouldOffer(
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
            lastAcknowledgedRevision: revision,
            installedRevision: nil
        ))
        #expect(!AgentPluginInstallOfferPolicy.shouldOffer(
            lastAcknowledgedRevision: nil,
            installedRevision: revision
        ))
        #expect(!AgentPluginInstallOfferPolicy.shouldOffer(
            lastAcknowledgedRevision: revision - 1,
            installedRevision: revision - 1
        ))

        let suite = "AgentPluginInstallResult-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!AgentPluginInstallOfferPolicy.recordInstallation(
            succeeded: false,
            in: defaults,
            buildVersion: "100"
        ))
        #expect(defaults.object(forKey: SettingsKeys.agentPluginInstalledRevision) == nil)
        #expect(!AgentPluginInstallOfferPolicy.isCurrentIntegrationInstalled(in: defaults))

        #expect(AgentPluginInstallOfferPolicy.recordInstallation(
            succeeded: true,
            in: defaults,
            buildVersion: "100"
        ))
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision) == revision)
        #expect(defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) == "100")
        #expect(AgentPluginInstallOfferPolicy.isCurrentIntegrationInstalled(in: defaults))
    }

    /// Revision 9 was the last integration that kept a working non-plugin
    /// delivery path, so declining its offer left agents connected. Once the
    /// plugins became the only path, that old "Not Now" must not suppress the
    /// launch offer.
    @Test("A launch offer declined while legacy wrapper delivery still worked is offered again.")
    func offerDeclinedBeforePluginOnlyDeliveryIsRepeated() {
        #expect(AgentPluginInstallOfferPolicy.shouldOffer(
            lastAcknowledgedRevision: 9,
            installedRevision: nil
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
}
