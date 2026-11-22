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
    private var antigravityAttempted = false

    func runAtLaunch(defaults: UserDefaults = .standard) async {
        let installer = AgentPluginInstaller(grafttyCLIPath: GrafttyApp.agentHookCLIPath())
        await runIfNeeded(defaults: defaults, update: {
            let plan = try await OffMainIO.run { try installer.prepare() }
            return await installer.refresh(plan)
        }, refreshHookAssets: { GrafttyApp.installAgentHookAssets() })
        // Antigravity needs no launch offer. Run it apart from this call so a
        // slow `agy` cannot hold back the Codex and Claude offer that follows.
        Task {
            await runAntigravityIfNeeded(defaults: defaults) {
                try await installer.autoInstallAntigravity()
            }
        }
    }

    func runAntigravityIfNeeded(
        defaults: UserDefaults,
        buildVersion: String? = AgentPluginInstallOfferPolicy.currentBuildVersion,
        install: () async throws -> AntigravityAutoInstallOutcome
    ) async {
        guard !antigravityAttempted,
              let buildVersion, !buildVersion.isEmpty,
              defaults.string(forKey: SettingsKeys.antigravityPluginInstalledBuildVersion) != buildVersion
        else { return }

        antigravityAttempted = true
        // Settings holds its own installs while this is set, so a manual
        // install cannot run `agy plugin install` alongside this one.
        isRunning = true
        defer { isRunning = false }
        do {
            switch try await install() {
            case .installed, .optedOut:
                defaults.set(buildVersion, forKey: SettingsKeys.antigravityPluginInstalledBuildVersion)
            case .cliNotFound:
                // Leave the build checkpoint unset so installing `agy` later
                // triggers automatic plugin installation on the next launch.
                break
            }
        } catch {
            // Leave the build checkpoint unset so transient errors retry on
            // the next launch without disturbing Codex/Claude update status.
            NSLog("[Graftty] Antigravity plugin auto-install failed: %@", String(describing: error))
        }
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
