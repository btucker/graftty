import Foundation
import Testing
@testable import GrafttyKit
@testable import Graftty

@Suite("Automatic provider plugin updates")
@MainActor
struct AgentPluginAutomaticUpdateTests {
    @Test("@spec AGENT-6.41: When bundled plugin content changes in a development build, the application shall use its content version as the automatic-refresh checkpoint.")
    func developmentPluginChangesRefreshCheckpoint() {
        let first = AgentPluginInstallOfferPolicy.checkpointVersion(
            build: "0.0.0-dev", pluginVersion: "0.0.0-dev.rabc"
        )
        let second = AgentPluginInstallOfferPolicy.checkpointVersion(
            build: "0.0.0-dev", pluginVersion: "0.0.0-dev.rdef"
        )
        #expect(first != second)
        #expect(first == "0.0.0-dev+0.0.0-dev.rabc")
        #expect(AgentPluginInstallOfferPolicy.checkpointVersion(
            build: "100.1.2", pluginVersion: "100.1.2"
        ) == "100.1.2")
    }

    @Test("@spec AGENT-6.37: When Graftty's plugin integration changes within a development build whose version string stays the same, the application shall refresh previously installed plugins and record the new integration revision after success.")
    func changedIntegrationRefreshesSameDevelopmentBuild() async {
        let suite = "AgentPluginSameBuildMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(8, forKey: SettingsKeys.agentPluginInstalledRevision)
        defaults.set("0.0.0-dev", forKey: SettingsKeys.agentPluginInstalledBuildVersion)
        var attempts = 0

        await AgentPluginAutomaticUpdate().runIfNeeded(
            defaults: defaults,
            buildVersion: "0.0.0-dev",
            update: {
                attempts += 1
                return Self.report(succeeded: true)
            },
            refreshHookAssets: {}
        )

        #expect(attempts == 1)
        #expect(defaults.integer(forKey: SettingsKeys.agentPluginInstalledRevision)
            == AgentPluginInstaller.integrationRevision)
    }

    @Test("""
    @spec AGENT-6.30: When a new Graftty build launches with a previously completed provider installation, the application shall refresh its bundled provider plugins in the background without another installation prompt, record the build only after complete success, and retry incomplete updates on a later launch.
    """)
    func updatesOncePerBuildAndRetriesAfterFailure() async {
        let suite = "AgentPluginAutoUpdate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AgentPluginInstaller.integrationRevision, forKey: SettingsKeys.agentPluginInstalledRevision)
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
        defaults.set(7, forKey: SettingsKeys.agentPluginInstalledRevision)
        let updater = AgentPluginAutomaticUpdate()
        await updater.runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
            throw AgentPluginInstallerError.bundledResourcesMissing
        }, refreshHookAssets: { Issue.record("Failed preparation refreshed hooks") })
        #expect(!updater.isRunning)
        #expect(updater.status?.contains("retry") == true)
        #expect(defaults.string(forKey: SettingsKeys.agentPluginInstalledBuildVersion) == nil)
    }

    @Test("A reentrant launch cannot start a second update.")
    func guardsReentryAndPreservesSelections() async {
        let suite = "AgentPluginAutoUpdateReentry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(7, forKey: SettingsKeys.agentPluginInstalledRevision)
        let updater = AgentPluginAutomaticUpdate()
        await updater.runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
            await updater.runIfNeeded(defaults: defaults, buildVersion: "100.60.00", update: {
                Issue.record("Reentrant update executed twice")
                return Self.report(succeeded: true)
            }, refreshHookAssets: {})
            return Self.report(succeeded: true)
        }, refreshHookAssets: {})
    }

    @Test("""
    @spec AGENT-6.171: When Graftty launches, the application shall automatically install or refresh the Antigravity plugin once per build checkpoint without requiring prior Codex or Claude plugin installation, preserve opt-outs, and leave the checkpoint unset when `agy` is missing or installation fails so future launches retry.
    """)
    func autoInstallsAntigravityOncePerBuildAndRetriesWhenMissingOrFailed() async {
        let suite = "AgentPluginAntigravityAutoInstall-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Missing `agy` leaves the checkpoint unset so installing `agy` later
        // triggers installation on the next launch.
        var attempts = 0
        await AgentPluginAutomaticUpdate().runAntigravityIfNeeded(defaults: defaults, buildVersion: "100.60.00") {
            attempts += 1
            return .cliNotFound
        }
        #expect(attempts == 1)
        #expect(defaults.string(forKey: SettingsKeys.antigravityPluginInstalledBuildVersion) == nil)

        // Transient failure also leaves the checkpoint unset for retry.
        await AgentPluginAutomaticUpdate().runAntigravityIfNeeded(defaults: defaults, buildVersion: "100.60.00") {
            attempts += 1
            throw AgentPluginInstallerError.bundledResourcesMissing
        }
        #expect(attempts == 2)
        #expect(defaults.string(forKey: SettingsKeys.antigravityPluginInstalledBuildVersion) == nil)

        // Successful auto-install works even when Codex/Claude were never installed.
        let updater = AgentPluginAutomaticUpdate()
        await updater.runAntigravityIfNeeded(defaults: defaults, buildVersion: "100.60.00") {
            attempts += 1
            // Settings holds its own installs while this is set, so a manual
            // install cannot run `agy plugin install` alongside this one.
            #expect(updater.isRunning)
            await updater.runAntigravityIfNeeded(defaults: defaults, buildVersion: "100.60.00") {
                Issue.record("Reentrant Antigravity install executed twice")
                return .installed
            }
            return .installed
        }
        #expect(!updater.isRunning)
        #expect(attempts == 3)
        #expect(defaults.string(forKey: SettingsKeys.antigravityPluginInstalledBuildVersion) == "100.60.00")

        // Same build does not reinstall.
        await AgentPluginAutomaticUpdate().runAntigravityIfNeeded(defaults: defaults, buildVersion: "100.60.00") {
            attempts += 1
            return .installed
        }
        #expect(attempts == 3)

        // New build refreshes, and explicit opt-out records the new build checkpoint.
        await AgentPluginAutomaticUpdate().runAntigravityIfNeeded(defaults: defaults, buildVersion: "100.61.00") {
            attempts += 1
            return .optedOut
        }
        #expect(attempts == 4)
        #expect(defaults.string(forKey: SettingsKeys.antigravityPluginInstalledBuildVersion) == "100.61.00")
    }

    private static func report(succeeded: Bool) -> AgentPluginInstallationReport {
        AgentPluginInstallationReport(results: [AgentPluginInstallResult(
            step: .init(provider: .codex, executable: "codex", arguments: []),
            output: nil,
            errorDescription: succeeded ? nil : "fixture failure"
        )])
    }
}
