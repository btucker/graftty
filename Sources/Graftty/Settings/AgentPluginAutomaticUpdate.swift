import Foundation
import Observation
import GrafttyKit

/// Refreshes an installation previously completed through Graftty. A missing
/// build checkpoint migrates existing installations on their next app launch.
@MainActor
@Observable
final class AgentPluginAutomaticUpdate {
    static let shared = AgentPluginAutomaticUpdate()

    private(set) var isRunning = false
    private(set) var status: String?
    private var attempted = false

    func runAtLaunch(defaults: UserDefaults = .standard) async {
        let installer = AgentPluginInstaller(grafttyCLIPath: GrafttyApp.agentHookCLIPath())
        await runIfNeeded(defaults: defaults, update: {
            let plan = try await OffMainIO.run { try installer.prepare() }
            return await installer.refresh(plan)
        }, refreshHookAssets: { GrafttyApp.installAgentHookAssets() })
    }

    func runIfNeeded(
        defaults: UserDefaults,
        buildVersion: String? = AgentPluginInstallOfferPolicy.currentBuildVersion,
        update: () async throws -> AgentPluginInstallationReport,
        refreshHookAssets: () -> Void
    ) async {
        guard !attempted,
              defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision) > 0,
              let buildVersion, !buildVersion.isEmpty,
              defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) != buildVersion
                || !AgentPluginInstallOfferPolicy.isCurrentIntegrationInstalled(in: defaults)
        else { return }

        attempted = true
        isRunning = true
        status = "Updating provider plugins…"
        defer { isRunning = false }
        do {
            let report = try await update()
            if report.succeeded {
                AgentPluginInstallOfferPolicy.recordInstalled(in: defaults, buildVersion: buildVersion)
                refreshHookAssets()
                status = "Provider plugins updated. Start new agent sessions to use them."
            } else {
                status = report.summary + " Graftty will retry on the next launch, or you can retry below."
            }
        } catch {
            status = "Could not update provider plugins: \(error). Graftty will retry on the next launch, or you can retry below."
        }
    }
}
