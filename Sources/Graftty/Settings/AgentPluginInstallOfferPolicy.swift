import Foundation
import GrafttyKit

enum AgentPluginInstallOfferPolicy {
    static func shouldOffer(
        agentTeamsEnabled: Bool,
        lastAcknowledgedRevision: Int?,
        installedRevision: Int?
    ) -> Bool {
        guard agentTeamsEnabled else { return false }
        let current = AgentPluginInstaller.integrationRevision
        return (lastAcknowledgedRevision ?? 0) < current
            && (installedRevision ?? 0) < current
    }

    static func shouldOffer(in defaults: UserDefaults) -> Bool {
        shouldOffer(
            agentTeamsEnabled: defaults.bool(forKey: SettingsKeys.agentTeamsEnabled),
            lastAcknowledgedRevision: defaults.object(
                forKey: SettingsKeys.agentPluginInstallOfferRevision
            ) as? Int,
            installedRevision: defaults.object(
                forKey: SettingsKeys.agentPluginInstalledRevision
            ) as? Int
        )
    }

    static func isCurrentIntegrationInstalled(installedRevision: Int?) -> Bool {
        (installedRevision ?? 0) >= AgentPluginInstaller.integrationRevision
    }

    static func isCurrentIntegrationInstalled(in defaults: UserDefaults) -> Bool {
        isCurrentIntegrationInstalled(
            installedRevision: defaults.object(
                forKey: SettingsKeys.agentPluginInstalledRevision
            ) as? Int
        )
    }

    static func recordAcknowledged(in defaults: UserDefaults) {
        defaults.set(
            AgentPluginInstaller.integrationRevision,
            forKey: SettingsKeys.agentPluginInstallOfferRevision
        )
    }

    static func recordInstalled(in defaults: UserDefaults) {
        defaults.set(
            AgentPluginInstaller.integrationRevision,
            forKey: SettingsKeys.agentPluginInstalledRevision
        )
        recordAcknowledged(in: defaults)
    }
}

enum AgentPluginIntegrationActivation {
    /// Activates plugin-owned hooks only after both provider installations
    /// complete. Until then the compatibility wrappers remain authoritative.
    @discardableResult
    static func apply(
        successfulInstallation: Bool,
        defaults: UserDefaults,
        refreshHookAssets: () -> Void
    ) -> Bool {
        defaults.set(
            successfulInstallation,
            forKey: SettingsKeys.nativeAgentMessagingEnabled
        )
        refreshHookAssets()
        guard successfulInstallation else { return false }
        AgentPluginInstallOfferPolicy.recordInstalled(in: defaults)
        return true
    }
}
