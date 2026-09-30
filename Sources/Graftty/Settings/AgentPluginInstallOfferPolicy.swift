import Foundation
import GrafttyKit

enum AgentPluginInstallOfferPolicy {
    static func shouldOffer(
        lastAcknowledgedRevision: Int?,
        installedRevision: Int?
    ) -> Bool {
        guard (installedRevision ?? 0) <= 0 else { return false }
        let current = AgentPluginInstaller.integrationRevision
        return (lastAcknowledgedRevision ?? 0) < current
    }

    static func shouldOffer(in defaults: UserDefaults) -> Bool {
        shouldOffer(
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

    static var currentBuildVersion: String? {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return checkpointVersion(build: build, pluginVersion: AgentPluginInstaller.appBuildPluginVersion)
    }

    static func checkpointVersion(build: String, pluginVersion: String?) -> String {
        guard AgentPluginInstaller.pluginVersion(forBuild: build) == nil,
              let pluginVersion else { return build }
        return "\(build)+\(pluginVersion)"
    }

    static func recordInstalled(
        in defaults: UserDefaults,
        buildVersion: String? = currentBuildVersion
    ) {
        defaults.set(
            AgentPluginInstaller.integrationRevision,
            forKey: SettingsKeys.agentPluginInstalledRevision
        )
        if let buildVersion, !buildVersion.isEmpty {
            defaults.set(buildVersion, forKey: SettingsKeys.agentPluginInstalledBuildVersion)
        }
        recordAcknowledged(in: defaults)
    }

    /// Records a provider installation attempt. Only a complete installation
    /// records the installed revision; an incomplete one records nothing so
    /// the launch offer and the Agent Teams warning keep prompting.
    @discardableResult
    static func recordInstallation(
        succeeded: Bool,
        in defaults: UserDefaults,
        buildVersion: String? = currentBuildVersion
    ) -> Bool {
        guard succeeded else { return false }
        recordInstalled(in: defaults, buildVersion: buildVersion)
        return true
    }
}
