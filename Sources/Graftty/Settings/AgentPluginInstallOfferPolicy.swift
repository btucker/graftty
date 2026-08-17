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
    static func userSelectionRevision(in defaults: UserDefaults) -> Int {
        defaults.integer(forKey: SettingsKeys.nativeAgentMessagingSelectionRevision)
    }

    /// Applies the user's messaging-mode selection independently of provider
    /// plugin availability. A user may intentionally choose native delivery
    /// before installing Codex, Claude, or either bundled plugin.
    @discardableResult
    static func applyUserSelection(
        enabled: Bool,
        defaults: UserDefaults,
        refreshHookAssets: () -> Void
    ) -> Bool {
        defaults.set(
            userSelectionRevision(in: defaults) &+ 1,
            forKey: SettingsKeys.nativeAgentMessagingSelectionRevision
        )
        defaults.set(enabled, forKey: SettingsKeys.nativeAgentMessagingEnabled)
        refreshHookAssets()
        return enabled
    }

    /// Records a complete provider installation and optionally enables native
    /// messaging when the accepted action was explicitly "Install and
    /// Enable." An install-only action, a failed installation, and any install
    /// superseded by a newer Settings selection preserve the independently
    /// selected messaging mode.
    @discardableResult
    static func apply(
        successfulInstallation: Bool,
        enableNativeMessagingOnSuccess: Bool,
        userSelectionRevisionAtStart: Int,
        defaults: UserDefaults,
        refreshHookAssets: () -> Void
    ) -> Bool {
        if successfulInstallation,
           enableNativeMessagingOnSuccess,
           userSelectionRevision(in: defaults) == userSelectionRevisionAtStart {
            defaults.set(true, forKey: SettingsKeys.nativeAgentMessagingEnabled)
        }
        refreshHookAssets()
        guard successfulInstallation else { return false }
        AgentPluginInstallOfferPolicy.recordInstalled(in: defaults)
        return true
    }
}
