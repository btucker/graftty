import Foundation
import Testing
@testable import GrafttyKit
@testable import Graftty

@Suite("Automatic provider plugin updates")
@MainActor
struct AgentPluginAutomaticUpdateTests {
    @Test("""
    @spec AGENT-6.30: When a new Graftty build launches with a previously completed provider installation, the application shall refresh its bundled provider plugins in the background without another installation prompt, preserve the messaging mode, record the build only after complete success, and retry incomplete updates on a later launch.
    """)
    func updatesOncePerBuildAndRetriesAfterFailure() async {
        let suite = "AgentPluginAutoUpdate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SettingsKeys.agentTeamsEnabled)
        defaults.set(AgentPluginInstaller.integrationRevision, forKey: SettingsKeys.agentPluginInstalledRevision)
        defaults.set(false, forKey: SettingsKeys.nativeAgentMessagingEnabled)
        var attempts = 0
        var refreshes = 0
        let updater = AgentPluginAutomaticUpdate()

        await updater.runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
            attempts += 1
            #expect(updater.isRunning)
            return Self.report(succeeded: true)
        }, refreshHookAssets: { refreshes += 1 })

        #expect(attempts == 1)
        #expect(refreshes == 1)
        #expect(!updater.isRunning)
        #expect(!defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
        #expect(defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) == "100.60.00")
        await AgentPluginAutomaticUpdate().runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
            attempts += 1
            return Self.report(succeeded: true)
        }, refreshHookAssets: {})
        #expect(attempts == 1)

        let failedLaunch = AgentPluginAutomaticUpdate()
        await failedLaunch.runIfNeeded(defaults: defaults, buildVersion: "100.61.00", update: {
            attempts += 1
            return Self.report(succeeded: false)
        }, refreshHookAssets: {})
        #expect(attempts == 2)
        #expect(defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) == "100.60.00")
        #expect(failedLaunch.status?.contains("retry") == true)
        await failedLaunch.runIfNeeded(defaults: defaults, buildVersion: "100.61.00", update: {
            attempts += 1
            return Self.report(succeeded: true)
        }, refreshHookAssets: {})
        #expect(attempts == 2)

        await AgentPluginAutomaticUpdate().runIfNeeded(defaults: defaults, buildVersion: "100.61.00", update: {
            attempts += 1
            return Self.report(succeeded: true)
        }, refreshHookAssets: {})
        #expect(attempts == 3)
        #expect(defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) == "100.61.00")
    }

    @Test("Uninstalled, declined, and unversioned development launches never auto-install.")
    func respectsInstallationAndLaunchEligibility() async {
        for (installed, build) in [
            (Optional<Int>.none, Optional("100.60.00")),
            (0, "100.60.00"),
            (7, nil),
            (7, ""),
        ] {
            let suite = "AgentPluginAutoUpdateEligibility-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(installed, forKey: SettingsKeys.agentPluginInstalledRevision)
            AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
            await AgentPluginAutomaticUpdate().runIfNeeded(defaults: defaults, buildVersion: build, update: {
                Issue.record("Ineligible launch invoked provider installation")
                return Self.report(succeeded: true)
            }, refreshHookAssets: { Issue.record("Ineligible launch refreshed hooks") })
            #expect(defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) == nil)
        }
    }

    @Test("Preparation failures clear the running state and remain eligible on a later launch.")
    func preparationFailureDoesNotRecordSuccess() async {
        let suite = "AgentPluginAutoUpdatePreparation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SettingsKeys.agentTeamsEnabled)
        defaults.set(7, forKey: SettingsKeys.agentPluginInstalledRevision)
        let updater = AgentPluginAutomaticUpdate()
        await updater.runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
            throw AgentPluginInstallerError.bundledResourcesMissing
        }, refreshHookAssets: { Issue.record("Failed preparation refreshed hooks") })
        #expect(!updater.isRunning)
        #expect(updater.status?.contains("retry") == true)
        #expect(defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) == nil)
    }

    @Test("A reentrant launch cannot start a second update or overwrite a messaging selection.")
    func guardsReentryAndPreservesSelections() async {
        let suite = "AgentPluginAutoUpdateReentry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SettingsKeys.agentTeamsEnabled)
        defaults.set(true, forKey: SettingsKeys.nativeAgentMessagingEnabled)
        defaults.set(7, forKey: SettingsKeys.agentPluginInstalledRevision)
        let updater = AgentPluginAutomaticUpdate()
        await updater.runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
            await updater.runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
                Issue.record("Reentrant update executed twice")
                return Self.report(succeeded: true)
            }, refreshHookAssets: {})
            defaults.set(false, forKey: SettingsKeys.nativeAgentMessagingEnabled)
            return Self.report(succeeded: true)
        }, refreshHookAssets: {})
        #expect(!defaults.bool(forKey: SettingsKeys.nativeAgentMessagingEnabled))
    }

    private static func report(succeeded: Bool) -> AgentPluginInstallationReport {
        AgentPluginInstallationReport(results: [AgentPluginInstallResult(
            step: .init(provider: .codex, executable: "codex", arguments: []),
            output: nil,
            errorDescription: succeeded ? nil : "fixture failure"
        )])
    }
}
