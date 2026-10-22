import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("Native agent plugin installer")
struct AgentPluginInstallerTests {
    @Test("Plugin providers are the hook runtimes, so every runtime has exactly one plugin provider and display name.")
    func pluginProvidersAreHookRuntimes() {
        let providers: [AgentPluginProvider] = TeamHookRuntime.allCases
        #expect(providers.map(\.rawValue) == ["codex", "claude"])
        #expect(providers.map(\.displayName) == ["Codex", "Claude"])
    }

    @Test("@spec AGENT-6.40: When a development build's bundled plugin content changes without a new app build number, the application shall give the plugin a distinct cache version.")
    func developmentPluginContentChangesCacheVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-plugin-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let skill = root.appendingPathComponent("SKILL.md")
        try Data("first".utf8).write(to: skill)
        let first = try #require(AgentPluginInstaller.developmentPluginVersion(forResourcesAt: root))
        try Data("second".utf8).write(to: skill)
        let second = try #require(AgentPluginInstaller.developmentPluginVersion(forResourcesAt: root))
        #expect(first != second)
        #expect(first.hasPrefix("0.0.0-dev.r"))
        let references = root.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let reference = references.appendingPathComponent("guide.md")
        try Data("first reference".utf8).write(to: reference)
        let withReference = try #require(AgentPluginInstaller.developmentPluginVersion(forResourcesAt: root))
        try Data("revised reference".utf8).write(to: reference)
        #expect(AgentPluginInstaller.developmentPluginVersion(forResourcesAt: root) != withReference)
    }

    @Test("""
    @spec AGENT-6.31: When a released Graftty build prepares provider plugins, the application shall use its normalized build version in both plugin manifests so provider caches refresh even when the source plugin version is unchanged.
    """)
    func appBuildVersionsInvalidateBothProviderCaches() throws {
        #expect(AgentPluginInstaller.pluginVersion(forBuild: "100.60.00") == "100.60.0")
        #expect(AgentPluginInstaller.pluginVersion(forBuild: "100.60.01") == "100.60.1")
        #expect(AgentPluginInstaller.pluginVersion(forBuild: "7") == "7.0.0")
        for invalid in ["", "dev", "1..2", "1.2.3.4", "-1.2.3"] {
            #expect(AgentPluginInstaller.pluginVersion(forBuild: invalid) == nil)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-versioned-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        for version in ["100.60.0", "100.61.0"] {
            _ = try AgentPluginInstaller(pluginVersion: version).prepare(destinationRoot: destination)
            for provider in ["codex", "claude"] {
                let data = try Data(contentsOf: destination.appendingPathComponent(
                    "\(provider)/plugins/graftty/.\(provider)-plugin/plugin.json"
                ))
                let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(manifest["version"] as? String == version)
                #expect(manifest["name"] as? String == "graftty")
            }
        }
    }

    @Test("""
    @spec AGENT-6.32: When Graftty automatically refreshes provider plugins, the application shall query provider-native installation state, update only installed and enabled user plugins, preserve removals and disabled plugins, and treat inventory failures as retryable errors while continuing with the other provider.
    """)
    func refreshPreservesProviderOptOutsAndReportsInventoryFailures() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-plugin-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let plan = try installer.prepare(destinationRoot: destination)
        let codex = #"{"installed":[{"pluginId":"graftty@graftty","installed":true,"enabled":true}]}"#
        let claude = #"[{"id":"graftty@graftty","scope":"user","enabled":true}]"#

        let executor = InventoryPluginCLIExecutor(codex: codex, claude: claude)
        let report = await installer.refresh(plan, executor: executor)
        #expect(report.succeeded)
        #expect(report.results.count == 4)
        #expect(await executor.mutations() == plan.installSteps.filter {
            $0.arguments.prefix(2) != ["plugin", "install"]
        }.map { Invocation(command: $0.executable, arguments: $0.arguments) })

        for (codexInventory, claudeInventory) in [
            (#"{"installed":[]}"#, "[]"),
            (codex.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#),
             claude.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#)),
            (codex.replacingOccurrences(of: #""installed":true"#, with: #""installed":false"#),
             claude.replacingOccurrences(of: #""scope":"user""#, with: #""scope":"project""#)),
            (codex.replacingOccurrences(of: "graftty@graftty", with: "other@graftty"),
             claude.replacingOccurrences(of: "graftty@graftty", with: "other@graftty")),
            (#"{"installed":[{"pluginId":"graftty@graftty","installed":true,"enabled":false},{"pluginId":"graftty-team@graftty","installed":true,"enabled":true}]}"#,
             #"[{"id":"graftty@graftty","scope":"user","enabled":false},{"id":"graftty-team@graftty","scope":"user","enabled":true}]"#),
        ] {
            let optedOut = InventoryPluginCLIExecutor(codex: codexInventory, claude: claudeInventory)
            #expect(await installer.refresh(plan, executor: optedOut).succeeded)
            #expect(await optedOut.mutations().isEmpty)
        }

        for invalid in ["not JSON", "{}", #"{"installed":[{"pluginId":"graftty@graftty"}]}"#, "missing-cli"] {
            let broken = InventoryPluginCLIExecutor(codex: invalid, claude: claude)
            let failed = await installer.refresh(plan, executor: broken)
            #expect(!failed.succeeded)
            #expect(failed.results.first?.step.provider == .codex)
            #expect(failed.results.first?.succeeded == false)
            #expect(await broken.mutations().map(\.command) == ["claude", "claude"])
        }
    }

    @Test("""
    @spec AGENT-6.42: When migrating an enabled legacy Graftty Team plugin, the application shall verify that the renamed plugin is enabled before removing the legacy plugin, verify removal, and report incomplete migration as a retryable failure.
    """)
    func refreshMigratesLegacyPluginAfterSuccessfulInstall() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-plugin-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let plan = try installer.prepare(destinationRoot: destination)
        let codex = #"{"installed":[{"pluginId":"graftty-team@graftty","installed":true,"enabled":true}]}"#
        let claude = #"[{"id":"graftty-team@graftty","scope":"user","enabled":true}]"#

        let executor = InventoryPluginCLIExecutor(
            codexInventories: [codex, Self.bothCodexPlugins, Self.currentCodexPlugin],
            claudeInventories: [claude, Self.bothClaudePlugins, Self.currentClaudePlugin]
        )
        let report = await installer.refresh(plan, executor: executor)
        #expect(report.succeeded)
        let mutations = await executor.mutations()
        #expect(mutations.map(\.arguments) == [
            plan.installSteps[0].arguments,
            plan.installSteps[1].arguments,
            ["plugin", "remove", "graftty-team@graftty"],
            plan.installSteps[2].arguments,
            plan.installSteps[3].arguments,
            plan.installSteps[4].arguments,
            ["plugin", "uninstall", "graftty-team@graftty", "--scope", "user"],
        ])

        let failing = InventoryPluginCLIExecutor(codex: codex, claude: "[]", failingMutation: 1)
        let failed = await installer.refresh(plan, executor: failing)
        #expect(!failed.succeeded)
        #expect(await failing.mutations().map(\.arguments).contains(
            ["plugin", "remove", "graftty-team@graftty"]
        ) == false)
    }

    @Test("""
    @spec AGENT-6.35: When the user installs the renamed Graftty plugin manually, the application shall remove installed legacy plugins only after verifying that the new installation is enabled, and verify that the legacy registration is gone.
    """)
    func manualInstallMigratesLegacyPlugins() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-plugin-manual-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let plan = try installer.prepare(destinationRoot: destination)
        let codex = #"{"installed":[{"pluginId":"graftty@graftty","installed":true,"enabled":true},{"pluginId":"graftty-team@graftty","installed":true,"enabled":true}]}"#
        let claude = #"[{"id":"graftty@graftty","scope":"user","enabled":true},{"id":"graftty-team@graftty","scope":"user","enabled":true}]"#
        let executor = InventoryPluginCLIExecutor(codexInventories: [codex, Self.currentCodexPlugin], claudeInventories: [claude, Self.currentClaudePlugin])

        let report = await installer.installReplacingLegacy(plan, executor: executor)

        #expect(report.succeeded)
        #expect(await executor.mutations().map(\.arguments) == plan.installSteps.map(\.arguments) + [
            ["plugin", "remove", "graftty-team@graftty"],
            ["plugin", "uninstall", "graftty-team@graftty", "--scope", "user"],
        ])

        let failing = InventoryPluginCLIExecutor(codexInventories: [codex], claudeInventories: [claude, Self.currentClaudePlugin], failingMutation: 1)
        let failed = await installer.installReplacingLegacy(plan, executor: failing)
        #expect(!failed.succeeded)
        #expect(await failing.mutations().map(\.arguments) == plan.installSteps.map(\.arguments) + [
            ["plugin", "uninstall", "graftty-team@graftty", "--scope", "user"],
        ])
    }

    private static let currentCodexPlugin = #"{"installed":[{"pluginId":"graftty@graftty","installed":true,"enabled":true}]}"#
    private static let currentClaudePlugin = #"[{"id":"graftty@graftty","scope":"user","enabled":true}]"#
    private static let bothCodexPlugins = #"{"installed":[{"pluginId":"graftty@graftty","installed":true,"enabled":true},{"pluginId":"graftty-team@graftty","installed":true,"enabled":true}]}"#
    private static let bothClaudePlugins = #"[{"id":"graftty@graftty","scope":"user","enabled":true},{"id":"graftty-team@graftty","scope":"user","enabled":true}]"#

    @Test("A successful install command cannot remove the legacy plugin until the replacement is enabled.")
    func migrationRejectsUnverifiedReplacement() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let plan = try installer.prepare(destinationRoot: destination)
        let old = Self.bothCodexPlugins.replacingOccurrences(of: #"{"pluginId":"graftty@graftty","installed":true,"enabled":true},"#, with: "")
        let executor = InventoryPluginCLIExecutor(codex: old, claude: "[]")
        let report = await installer.refresh(plan, executor: executor)
        #expect(!report.succeeded)
        #expect(report.results.contains { $0.errorDescription?.contains("not enabled") == true })
        #expect(await executor.mutations().contains { $0.arguments.prefix(2) == ["plugin", "remove"] } == false)
    }

    @Test("A successful uninstall command that leaves a legacy registration must remain retryable.")
    func migrationVerifiesRemovalAndRetries() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let plan = try installer.prepare(destinationRoot: destination)
        let executor = InventoryPluginCLIExecutor(codex: Self.bothCodexPlugins, claude: "[]")
        let report = await installer.refresh(plan, executor: executor)
        #expect(!report.succeeded)
        #expect(report.results.contains { $0.errorDescription?.contains("still installed") == true })

        let retry = InventoryPluginCLIExecutor(
            codexInventories: [Self.bothCodexPlugins, Self.bothCodexPlugins, Self.currentCodexPlugin],
            claudeInventories: ["[]"]
        )
        #expect(await installer.refresh(plan, executor: retry).succeeded)
    }

    @Test("Disabled legacy registrations are removed when their replacement is enabled.")
    func removesDisabledLegacyRegistration() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let plan = try installer.prepare(destinationRoot: destination)
        let disabled = Self.bothCodexPlugins.replacingOccurrences(of: #""graftty-team@graftty","installed":true,"enabled":true"#, with: #""graftty-team@graftty","installed":true,"enabled":false"#)
        let executor = InventoryPluginCLIExecutor(
            codexInventories: [disabled, disabled, Self.currentCodexPlugin], claudeInventories: ["[]"]
        )
        #expect(await installer.refresh(plan, executor: executor).succeeded)
        #expect(await executor.mutations().contains { $0.arguments == ["plugin", "remove", "graftty-team@graftty"] })
    }

    @Test("A provider-specific install never queries or removes the unselected provider's plugins.")
    func migrationStaysWithinSelectedProvider() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let full = try installer.prepare(destinationRoot: destination)
        let selected = AgentPluginSetupPlan(rootDirectory: full.rootDirectory, installSteps: full.installSteps.filter { $0.provider == .codex })
        let executor = InventoryPluginCLIExecutor(codex: Self.currentCodexPlugin, claude: "missing-cli")
        #expect(await installer.installReplacingLegacy(selected, executor: executor).succeeded)
    }

    @Test("""
    @spec AGENT-6.51: If Codex retains an enabled legacy Graftty Team registration that its native plugin inventory omits, then the application shall migrate that registration, preserve an explicitly disabled replacement, and verify that native removal clears the legacy registration.
    """)
    func migratesOrphanedCodexRegistration() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let configuration = destination.appendingPathComponent("config.toml")
        let installer = AgentPluginInstaller(codexConfigurationURL: configuration, claudeSettingsURL: destination.appendingPathComponent("claude-settings.json"))
        let plan = try installer.prepare(destinationRoot: destination)
        let legacy = "[plugins.\"graftty-team@graftty\"]\nenabled = true\n"
        try Data(legacy.utf8).write(to: configuration)
        let executor = InventoryPluginCLIExecutor(
            codexInventories: [#"{"installed":[]}"#, Self.currentCodexPlugin, Self.currentCodexPlugin],
            claudeInventories: ["[]"], codexConfigurationURL: configuration
        )
        #expect(await installer.refresh(plan, executor: executor).succeeded)
        #expect(await executor.mutations().map(\.arguments) == plan.installSteps.filter { $0.provider == .codex }.map(\.arguments) + [["plugin", "remove", "graftty-team@graftty"]])
        #expect(try String(contentsOf: configuration, encoding: .utf8).isEmpty)

        // An invisible but still registered plugin must fail verification too.
        try Data(legacy.utf8).write(to: configuration)
        let stuck = InventoryPluginCLIExecutor(codex: Self.currentCodexPlugin, claude: "[]")
        #expect(await installer.refresh(plan, executor: stuck).succeeded == false)

        let disabled = legacy + "[plugins.\"graftty@graftty\"]\nenabled = false\n"
        try Data(disabled.utf8).write(to: configuration)
        let optedOut = InventoryPluginCLIExecutor(codex: #"{"installed":[]}"#, claude: "[]")
        #expect(await installer.refresh(plan, executor: optedOut).succeeded)
        #expect(await optedOut.mutations().isEmpty)
    }

    @Test("""
    @spec AGENT-6.52: If Claude retains a legacy Graftty Team registration in user settings, then the application shall verify that the replacement is enabled, remove the legacy registration even when native inventory omits it, preserve other settings and explicit opt-outs, and report incomplete cleanup as a retryable failure.
    """, arguments: [true, false])
    func migratesOrphanedClaudeRegistration(legacyEnabled: Bool) async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let settingsURL = destination.appendingPathComponent("claude-settings.json")
        let installer = AgentPluginInstaller(
            codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: settingsURL
        )
        let plan = try installer.prepare(destinationRoot: destination)
        let settings: [String: Any] = [
            "enabledPlugins": ["graftty-team@graftty": legacyEnabled, "other@example": false],
            "permissions": ["allow": ["Read"]], "customFutureKey": ["keep": "this"],
        ]
        let original = try JSONSerialization.data(withJSONObject: settings)
        try original.write(to: settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        let executor = InventoryPluginCLIExecutor(
            codexInventories: [#"{"installed":[]}"#],
            claudeInventories: legacyEnabled ? ["[]", Self.currentClaudePlugin, Self.currentClaudePlugin] : [Self.currentClaudePlugin]
        )
        #expect(await installer.refresh(plan, executor: executor).succeeded)
        let cleaned = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let enabled = try #require(cleaned["enabledPlugins"] as? [String: Bool])
        #expect(enabled == ["other@example": false])
        #expect(cleaned["permissions"] as? [String: [String]] == ["allow": ["Read"]])
        #expect(cleaned["customFutureKey"] as? [String: String] == ["keep": "this"])
        #expect(try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? Int == 0o600)
        #expect(await executor.mutations().map(\.arguments) == plan.installSteps.filter {
            $0.provider == .claude && (legacyEnabled || $0.arguments.prefix(2) != ["plugin", "install"])
        }.map(\.arguments))

        // Never remove the old entry when replacement verification fails.
        try original.write(to: settingsURL)
        let missingReplacement = InventoryPluginCLIExecutor(codex: #"{"installed":[]}"#, claude: "[]")
        if legacyEnabled { #expect(await installer.refresh(plan, executor: missingReplacement).succeeded == false) }
        #expect(try Data(contentsOf: settingsURL) == original)

        var optedOut = settings
        optedOut["enabledPlugins"] = ["graftty-team@graftty": true, "graftty@graftty": false]
        let disabled = try JSONSerialization.data(withJSONObject: optedOut)
        try disabled.write(to: settingsURL)
        let disabledReplacement = InventoryPluginCLIExecutor(codex: #"{"installed":[]}"#, claude: Self.currentClaudePlugin)
        #expect(await installer.refresh(plan, executor: disabledReplacement).succeeded)
        #expect(await disabledReplacement.mutations().isEmpty)
        #expect(try Data(contentsOf: settingsURL) == disabled)
    }

    @Test("Claude cleanup removes a settings entry left behind by a successful native uninstall.")
    func claudeUninstallClearsResidualSetting() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let settingsURL = destination.appendingPathComponent("claude-settings.json")
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: settingsURL)
        let plan = try installer.prepare(destinationRoot: destination)
        try Data(#"{"enabledPlugins":{"graftty-team@graftty":true,"graftty@graftty":true}}"#.utf8).write(to: settingsURL)
        let executor = InventoryPluginCLIExecutor(
            codexInventories: [#"{"installed":[]}"#],
            claudeInventories: [Self.bothClaudePlugins, Self.bothClaudePlugins, Self.currentClaudePlugin, Self.currentClaudePlugin]
        )
        #expect(await installer.refresh(plan, executor: executor).succeeded)
        #expect(await executor.mutations().contains { $0.arguments == ["plugin", "uninstall", "graftty-team@graftty", "--scope", "user"] })
        let cleaned = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        #expect(cleaned["enabledPlugins"] as? [String: Bool] == ["graftty@graftty": true])
    }

    @Test("Invalid Claude settings are a retryable failure and remain untouched.")
    func claudeMigrationRejectsInvalidSettings() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let settingsURL = destination.appendingPathComponent("claude-settings.json")
        let installer = AgentPluginInstaller(codexConfigurationURL: destination.appendingPathComponent("config.toml"), claudeSettingsURL: settingsURL)
        let plan = try installer.prepare(destinationRoot: destination)
        for contents in ["broken JSON", #"{"enabledPlugins":{"graftty-team@graftty":"true"}}"#] {
            let original = Data(contents.utf8)
            try original.write(to: settingsURL)
            let executor = InventoryPluginCLIExecutor(codex: #"{"installed":[]}"#, claude: Self.currentClaudePlugin)
            #expect(await installer.refresh(plan, executor: executor).succeeded == false)
            #expect(await executor.mutations().isEmpty)
            #expect(try Data(contentsOf: settingsURL) == original)
        }
    }

    @Test("Codex plugin switches honor quoted tables, dotted keys, comments, and multiline user text.")
    func codexPluginRegistrationParsing() {
        let id = "graftty-team@graftty"
        for config in [
            "[plugins.\"graftty-team@graftty\"] # comment\nenabled = true # comment",
            "[ 'plugins' . 'graftty-team@graftty' ]\n'enabled' = true",
            "plugins.\"graftty-team@graftty\".enabled=true",
            "[plugins.\"graftty-team@graftty\"]\r\nenabled = true\r\n",
            "[plugins]\n\"graftty-team@graftty\".enabled=true",
        ] {
            #expect(CodexHomeMirror.pluginEnablement(in: config) == [id: true])
        }
        let fake = "instructions = \"\"\"\n[plugins.\"graftty-team@graftty\"]\nenabled = true\n\"\"\"\n[plugins.\"graftty@graftty\"]\nenabled = false"
        #expect(CodexHomeMirror.pluginEnablement(in: fake) == ["graftty@graftty": false])
        #expect(CodexHomeMirror.pluginEnablement(in: "[plugins.\"graftty-team@graftty\"]\nenabled = \"true\"").isEmpty)
    }

    @Test("""
    @spec AGENT-6.29: When bundled provider skills or manifests use symbolic links, the application shall materialize their contents as regular files so each prepared plugin remains usable without the source bundle or sibling provider.
    """)
    func sharedFilesSurviveIndependentPluginCaching() throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("graftty-shared-plugin-files-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        let source = temporary.appendingPathComponent("source")
        try fileManager.copyItem(
            at: try #require(AgentPluginInstaller.bundledResourceRoot()),
            to: source
        )
        let claudeRoot = source.appendingPathComponent("claude/plugins/graftty")
        let links = [
            "skills/graftty/SKILL.md": "../../../../../codex/plugins/graftty/skills/graftty/SKILL.md",
            "skills/graftty-team/SKILL.md": "../../../../../codex/plugins/graftty/skills/graftty-team/SKILL.md",
            ".claude-plugin/plugin.json": "../../../../codex/plugins/graftty/.codex-plugin/plugin.json",
            "skills/graftty-open/SKILL.md": "../../../../../codex/plugins/graftty/skills/graftty-open/SKILL.md",
            "skills/graftty-preview/SKILL.md": "../../../../../codex/plugins/graftty/skills/graftty-preview/SKILL.md",
        ]
        for (path, target) in links {
            let link = claudeRoot.appendingPathComponent(path)
            try fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        let expectedRecapSkill = try Data(contentsOf: claudeRoot
            .appendingPathComponent("skills/graftty/SKILL.md"))
        let expectedTeamSkill = try Data(contentsOf: claudeRoot
            .appendingPathComponent("skills/graftty-team/SKILL.md"))
        let expectedOpenSkill = try Data(contentsOf: claudeRoot
            .appendingPathComponent("skills/graftty-open/SKILL.md"))
        let expectedImageSkill = try Data(contentsOf: claudeRoot
            .appendingPathComponent("skills/graftty-preview/SKILL.md"))
        let expectedManifest = try Data(contentsOf: claudeRoot
            .appendingPathComponent(".claude-plugin/plugin.json"))
        let destination = temporary.appendingPathComponent("prepared")
        _ = try AgentPluginInstaller(resourceRoot: source).prepare(destinationRoot: destination)

        for provider in ["codex", "claude"] {
            try fileManager.copyItem(
                at: destination.appendingPathComponent("\(provider)/plugins/graftty"),
                to: temporary.appendingPathComponent("cached-\(provider)")
            )
        }
        try fileManager.removeItem(at: source)
        try fileManager.removeItem(at: destination)

        for provider in ["codex", "claude"] {
            let cached = temporary.appendingPathComponent("cached-\(provider)")
            for (path, expected) in [
                "skills/graftty/SKILL.md": expectedRecapSkill,
                "skills/graftty-team/SKILL.md": expectedTeamSkill,
                "skills/graftty-open/SKILL.md": expectedOpenSkill,
                "skills/graftty-preview/SKILL.md": expectedImageSkill,
                ".\(provider)-plugin/plugin.json": expectedManifest,
            ] {
                let file = cached.appendingPathComponent(path)
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                #expect(attributes[.type] as? FileAttributeType == .typeRegular)
                #expect(try Data(contentsOf: file) == expected)
            }
        }
    }

    @Test("@spec AGENT-6.54: When Graftty prepares provider plugins with linked supporting reference directories or files, the application shall materialize those resources so each cached plugin remains self-contained after the source and sibling provider are removed.")
    func linkedSkillReferencesSurviveIndependentCaching() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("graftty-skill-references-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let source = temporary.appendingPathComponent("source")
        try fm.copyItem(at: try #require(AgentPluginInstaller.bundledResourceRoot()), to: source)
        let references = temporary.appendingPathComponent("references/nested")
        try fm.createDirectory(at: references, withIntermediateDirectories: true)
        let original = temporary.appendingPathComponent("original.md")
        let expected = Data("# Supporting guidance\n".utf8)
        try expected.write(to: original)
        try fm.createSymbolicLink(at: references.appendingPathComponent("guide.md"), withDestinationURL: original)
        for provider in ["codex", "claude"] {
            let link = source.appendingPathComponent("\(provider)/plugins/graftty/skills/graftty-team/references")
            if fm.fileExists(atPath: link.path) { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: references.deletingLastPathComponent())
        }
        let prepared = temporary.appendingPathComponent("prepared")
        _ = try AgentPluginInstaller(resourceRoot: source).prepare(destinationRoot: prepared)
        for provider in ["codex", "claude"] {
            try fm.copyItem(at: prepared.appendingPathComponent("\(provider)/plugins/graftty"),
                            to: temporary.appendingPathComponent("cached-\(provider)"))
        }
        for item in [source, prepared, references.deletingLastPathComponent(), original] {
            try fm.removeItem(at: item)
        }
        for provider in ["codex", "claude"] {
            let cached = temporary.appendingPathComponent("cached-\(provider)/skills/graftty-team/references")
            #expect(try fm.attributesOfItem(atPath: cached.path)[.type] as? FileAttributeType == .typeDirectory)
            let guide = cached.appendingPathComponent("nested/guide.md")
            #expect(try fm.attributesOfItem(atPath: guide.path)[.type] as? FileAttributeType == .typeRegular)
            #expect(try Data(contentsOf: guide) == expected)
        }
    }

    @Test("Cyclic supporting links fail preparation without replacing installed plugins.")
    func cyclicSkillReferencesPreserveInstalledSnapshot() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("graftty-cyclic-reference-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        let prepared = temporary.appendingPathComponent("prepared")
        _ = try AgentPluginInstaller().prepare(destinationRoot: prepared)
        let skillPath = "codex/plugins/graftty/skills/graftty-team/SKILL.md"
        let original = try Data(contentsOf: prepared.appendingPathComponent(skillPath))
        let referencesPath = "codex/plugins/graftty/skills/graftty-team/references"
        let previousReferences = try fm.contentsOfDirectory(atPath: prepared.appendingPathComponent(referencesPath).path).sorted()
        let source = temporary.appendingPathComponent("source")
        try fm.copyItem(at: try #require(AgentPluginInstaller.bundledResourceRoot()), to: source)
        let references = source.appendingPathComponent("codex/plugins/graftty/skills/graftty-team/references")
        try fm.createDirectory(at: references, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: references.appendingPathComponent("self.md").path,
                                  withDestinationPath: "self.md")
        #expect(throws: (any Error).self) {
            try AgentPluginInstaller(resourceRoot: source).prepare(destinationRoot: prepared)
        }
        #expect(try Data(contentsOf: prepared.appendingPathComponent(skillPath)) == original)
        #expect(try fm.contentsOfDirectory(atPath: prepared.appendingPathComponent(referencesPath).path).sorted() == previousReferences)
        #expect(try fm.contentsOfDirectory(atPath: prepared.path).sorted() == ["claude", "codex"])
    }

    /// Read the named skill's entrypoint and references from each prepared
    /// provider, asserting that every Markdown resource is a regular file.
    private func preparedSkillTexts(named skill: String) throws -> [String] {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-\(skill)-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)
        return try ["codex", "claude"].map { provider in
            let directory = destination.appendingPathComponent("\(provider)/plugins/graftty/skills/\(skill)")
            let documents = try SkillMarkdown.documents(in: directory)
            #expect(documents["SKILL.md"] != nil, "Packaged documents: \(documents.keys.sorted())")
            return documents.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
        }
    }

    @Test("@spec AGENT-6.55: When Graftty packages progressive skill guidance, the application shall retain readable relative links within each independent provider plugin, with supporting procedures reachable from their skill entrypoints.")
    func packagedSkillLinksStayWithinIndependentProviderCaches() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("graftty-skill-links-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        let prepared = temporary.appendingPathComponent("prepared")
        _ = try AgentPluginInstaller().prepare(destinationRoot: prepared)
        for provider in ["codex", "claude"] {
            try fm.copyItem(at: prepared.appendingPathComponent("\(provider)/plugins/graftty"),
                            to: temporary.appendingPathComponent("cached-\(provider)"))
        }
        try fm.removeItem(at: prepared)
        for provider in ["codex", "claude"] {
            try SkillMarkdown.validateLinks(in: temporary.appendingPathComponent("cached-\(provider)"))
        }
    }

    @Test("""
    @spec AGENT-6.34: When Graftty prepares provider plugins, the application shall bundle a `graftty-open` skill for both providers that routes finished review artifacts through graftty preview and documents external file opening, URL routing, worktree scope and mobile limits.
    """)
    func preparesOpenSkillForBothProviders() throws {
        for skill in try preparedSkillTexts(named: "graftty-open") {
            for token in ["name: graftty-open", "graftty open", "20 MB", "15 minutes", "http://localhost:3000"] {
                #expect(skill.contains(token))
            }
        }
    }

    @Test("""
    @spec AGENT-6.50: When Graftty prepares provider plugins, the application shall bundle a `graftty-preview` skill for both providers that directs agents to resolve Markdown image references, include Markdown image embeds in responses, show files with graftty preview in a native tray and create self-contained HTML when a visual explains something better, forbid imgcat, kitten icat, direct tty writes, and terminal queries, and report failures or missing previews without claiming delivery before falling back to graftty open.
    """)
    func preparesImageSkillForBothProviders() throws {
        for skill in try preparedSkillTexts(named: "graftty-preview") {
            #expect(skill.contains("name: graftty-preview"))
            #expect(skill.contains("![Chart](./output/chart.png)"))
            #expect(skill.contains("![Refined sidebar](</absolute/path with spaces/sidebar.png>)"))
            #expect(skill.contains("containing Markdown file's directory"))
            #expect(skill.contains("graftty preview"))
            #expect(skill.contains("native tray"))
            #expect(skill.contains("!["))
            #expect(skill.contains("acknowledges"))
            #expect(skill.contains("imgcat"))
            #expect(skill.contains("kitten icat"))
            #expect(skill.contains("/dev/tty"))
            #expect(skill.contains("terminal query"))
            #expect(skill.contains("graftty open"))
        }
    }

    @Test("""
    @spec IMAGE-1.6: When Graftty installs the graftty-preview skill, the skill shall describe the movable and resizable macOS tray and the owning Mobile pane's Preview control for native Quick Look, explain collection navigation and automatic mobile opening, and acknowledge requests without claiming the user saw the image.
    """)
    func imageSkillDescribesNativePreviewOnLeadingDevice() throws {
        for skill in try preparedSkillTexts(named: "graftty-preview") {
            #expect(skill.contains("Graftty Mobile"))
            #expect(skill.contains("focused owning pane"))
            #expect(skill.contains("Preview control"))
            #expect(skill.contains("Quick Look with zoom and sharing"))
            #expect(skill.contains("Arrival preserves terminal focus"))
            #expect(skill.contains("Drag the header"))
            #expect(skill.contains("resize"))
            #expect(skill.contains("previous and next"))
            #expect(skill.contains("self-contained HTML"))
            #expect(skill.contains("zoom"))
            #expect(skill.contains("Close"))
            #expect(!skill.contains("Drew <name>"))
        }
    }

    @Test("""
    @spec AGENT-6.28: When Graftty installs provider hooks, the application shall subscribe to blocking question or plan-review tool starts for both providers and Claude permission requests, while Codex pre-review permission events and Stop shall not be treated as needs-input signals.
    """)
    func providerHooksCaptureExplicitAttentionSignals() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugin-attention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)

        for provider in ["codex", "claude"] {
            let data = try Data(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty/hooks/hooks.json"))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hooks = try #require(root["hooks"] as? [String: Any])

            #expect(hooks["PreToolUse"] != nil)
            #expect(hooks["UserPromptSubmit"] != nil)
            let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
            #expect(preToolUse.first?["matcher"] as? String == (provider == "claude"
                ? "AskUserQuestion|ExitPlanMode"
                : "request_user_input|exit_plan_mode"))
            var boundedEvents = ["PreToolUse", "UserPromptSubmit"]
            if provider == "claude" {
                #expect(hooks["PermissionRequest"] != nil)
                #expect(hooks["PostToolUseFailure"] != nil)
                boundedEvents += ["PermissionRequest", "PostToolUseFailure"]
            } else {
                #expect(hooks["PermissionRequest"] == nil)
                #expect(hooks["PostToolUseFailure"] == nil)
            }
            for event in boundedEvents {
                let groups = try #require(hooks[event] as? [[String: Any]])
                let handlers = groups.flatMap { group in
                    (group["hooks"] as? [[String: Any]]) ?? []
                }
                #expect(!handlers.isEmpty)
                #expect(handlers.allSatisfy { $0["timeout"] as? Int == 2 })
            }
            let stop = try #require(hooks["Stop"] as? [[String: Any]])
            let stopCommands = stop.flatMap { group in
                (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
            }
            #expect(stopCommands.allSatisfy { !$0.contains("needs-input") })
        }
    }

    @Test("""
    @spec AGENT-6.10: When the user prepares native agent integration, the application shall materialize validated Codex and Claude marketplace snapshots containing separate Graftty Attention and team skills plus lifecycle hooks that use the bundled CLI and honor the hook opt-out, then present provider-native install and update commands without silently changing provider trust configuration.
    """)
    func preparesBothProviderMarketplacesAndCommands() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = try AgentPluginInstaller(
            grafttyCLIPath: "/Applications/Graftty.app/Contents/Helpers/graftty"
        ).prepare(destinationRoot: destination)

        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent("codex/plugins/graftty/skills/graftty-team/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent("claude/plugins/graftty/skills/graftty-team/SKILL.md").path))
        for provider in ["codex", "claude"] {
            let recapSkill = try String(contentsOf: destination
                .appendingPathComponent("\(provider)/plugins/graftty/skills/graftty/SKILL.md"))
            #expect(recapSkill.contains("graftty attention report --stdin"))
            #expect(recapSkill.contains("emojiAlternatives"))
            #expect(!recapSkill.contains("graftty team send"))
        }
        #expect(try String(contentsOf: destination
            .appendingPathComponent("codex/plugins/graftty/hooks/hooks.json"))
            .contains("--skill-managed"))
        #expect(plan.commands.count == 5)
        #expect(plan.commands[0].contains("codex plugin marketplace add"))
        #expect(plan.commands[2].contains("claude plugin marketplace add"))
        #expect(plan.installSteps.map(\.provider) == [
            .codex, .codex, .claude, .claude, .claude,
        ])
        #expect(plan.installSteps[0].arguments == ["plugin", "marketplace", "add", destination
            .appendingPathComponent("codex", isDirectory: true).path])
        #expect(plan.installSteps[3].arguments == [
            "plugin", "install", "graftty@graftty", "--scope", "user",
        ])
        #expect(plan.installSteps[4].arguments == [
            "plugin", "update", "graftty@graftty", "--scope", "user",
        ])
        for provider in ["codex", "claude"] {
            let skill = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty/skills/graftty-team/SKILL.md"))
            for token in ["#<runtime>-<12hex>", "#<runtime>", "graftty team reply", "`id` attribute", "<graftty-peer-message>", "--fallback", "references/routing.md"] {
                #expect(skill.contains(token))
            }
            let hooks = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty/hooks/hooks.json"))
            let expectedHookCount = provider == "claude" ? 7 : 5
            #expect(hooks.components(separatedBy: "GRAFTTY_DISABLE_AGENT_HOOKS").count - 1 == expectedHookCount)
            #expect(hooks.contains("/Applications/Graftty.app/Contents/Helpers/graftty team hook"))
        }
        let claudeManifest = try String(contentsOf: destination
            .appendingPathComponent("claude/plugins/graftty/.claude-plugin/plugin.json"))
        #expect(claudeManifest.contains(#""version": "0.3.2""#))
        let codexManifest = try String(contentsOf: destination
            .appendingPathComponent("codex/plugins/graftty/.codex-plugin/plugin.json"))
        #expect(codexManifest.contains(#""version": "0.3.2""#))
    }

    @Test("""
    @spec AGENT-6.21: When Graftty materializes a provider team skill, the skill shall explain the durable hierarchical `.graftty/**/GRAFTTY.md` instruction system's repository and worktree scopes, its `## Private` sharing boundary, next-session delivery, and the authorization required before editing an instruction file.
    """)
    func materializedSkillsExplainDurableInstructionFiles() throws {
        for skill in try preparedSkillTexts(named: "graftty-team") {
            for token in ["references/durable-roles.md", ".graftty/GRAFTTY.md", ".graftty/<parent>/GRAFTTY.md", ".graftty/<parent>/<leaf>/GRAFTTY.md", "## Private"] {
                #expect(skill.contains(token))
            }
        }
    }

    @Test("""
    @spec AGENT-6.26: When Graftty materializes a provider team skill, the skill shall limit delegation to user requests, permit reuse for an active assignment or established role, direct unrelated new tasks to fresh agents after a PR merges unless the user requests reuse, limit peer messages to necessary active-task coordination, distinguish delegation from creating a worktree alone, and require child reachability before the parent relinquishes the delegated scope.
    """)
    func materializedSkillsExplainRealWorktreeDelegation() throws {
        for skill in try preparedSkillTexts(named: "graftty-team") {
            for token in ["graftty worktree add <name> --agent <codex|claude> --prompt-stdin", "Parent exact address:", "Parent fallback address:", "graftty team list --json", "references/worktrees.md"] {
                #expect(skill.contains(token))
            }
            for policy in [
                "Delegate only when the user asks",
                "Reuse an agent for a continuation of its active assignment or work covered by its established role",
                "For unrelated new work, launch a fresh agent",
                "A merged PR ends that task assignment",
                "Send a peer message only when it is needed to complete the active task",
            ] {
                #expect(skill.contains(policy))
            }
        }
    }

    @Test("""
    @spec AGENT-6.56: When Graftty materializes a provider team skill, the skill shall direct agents to use STE-inspired controlled English with direct requests, one instruction per sentence, consistent technical terms, conditions before actions, and factual results that distinguish passed, failed, pending, and not-run checks.
    """)
    func materializedTeamSkillExplainsControlledEnglish() throws {
        for skill in try preparedSkillTexts(named: "graftty-team") {
            for rule in [
                "Use STE-inspired controlled English",
                "Write one instruction per sentence",
                "Put conditions before the actions",
                "Use the same term for the same thing",
                "Distinguish passed, failed, pending, and not-run checks",
            ] {
                #expect(skill.contains(rule))
            }
        }
    }

    @Test("""
    @spec AGENT-6.16: While a provider sandbox denies a `graftty team` command access to a live Graftty control socket with `EPERM` or `errno 1`, the installed team skill shall instruct the agent to verify the socket and owner read-only, retry the same command with narrowly scoped elevated permission, and avoid deleting or recreating the socket or restarting Graftty as a first response.
    """)
    func materializedSkillsDiagnoseSandboxDeniedControlSocket() throws {
        for skill in try preparedSkillTexts(named: "graftty-team") {
            for token in ["references/socket-diagnosis.md", "EPERM", "errno 1", "$GRAFTTY_SOCK"] {
                #expect(skill.contains(token))
            }
        }
    }

    @Test("""
    @spec AGENT-6.36: When Graftty installs provider skills, the recap skill shall explain its private file handoff and the team skill shall direct Codex agents in a restricted sandbox to request narrowly scoped permission before their first main control-socket command and retain that choice for subsequent commands without changing provider policy.
    """)
    func materializedSkillsSeparateAttentionHandoffFromMainSocket() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-permission-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)
        for provider in ["codex", "claude"] {
            let skills = destination.appendingPathComponent("\(provider)/plugins/graftty/skills")
            let recap = try String(contentsOf: skills.appendingPathComponent("graftty/SKILL.md"), encoding: .utf8)
            let team = try String(contentsOf: skills.appendingPathComponent("graftty-team/SKILL.md"), encoding: .utf8)
            let permission = try #require(team.range(of: "require_escalated"))
            let roster = try #require(team.range(of: "graftty team list --json"))
            #expect(permission.lowerBound < roster.lowerBound)
            #expect(team.contains("graftty attention report --stdin"))
            #expect(recap.contains("../graftty-team/SKILL.md"))
            #expect(!recap.contains("require_escalated"))
        }
    }

    @Test("""
    @spec AGENT-6.38: When Graftty installs the recap skill, the application shall ask agents to lead with the stable problem being solved and why it matters, followed by verified progress, next steps, retained decisions, meaningful checkpoints, and task-related emoji choices, with a user question only when input is needed.
    """)
    func materializedRecapSkillRequestsTaskContext() throws {
        for skill in try preparedSkillTexts(named: "graftty") {
            let recap = try SkillMarkdown.recapExample(in: skill)
            for key in ["title", "context", "completed", "next", "emoji"] {
                #expect((recap[key] as? String)?.isEmpty == false)
            }
            let alternatives = try #require(recap["emojiAlternatives"] as? [String])
            #expect(alternatives.count <= 3)
            #expect(Set(alternatives).count == alternatives.count)
            #expect(!alternatives.contains(try #require(recap["emoji"] as? String)))
            #expect(recap["need"] == nil)
            let checkpoint = try #require(recap["checkpoint"] as? String)
            let decisions = try #require(recap["decisions"] as? [String])
            #expect(!checkpoint.isEmpty)
            #expect(!decisions.isEmpty)
            let data = try JSONSerialization.data(withJSONObject: recap)
            let report = try JSONDecoder().decode(AttentionRecap.self, from: data)
            #expect(report.isValid)
            #expect(report.purposeChanged != true)
        }
    }

    @Test("Bundled plugin resources resolve in both flat and Contents/Resources bundle layouts.")
    func bundledResourceRootHandlesBothBundleLayouts() throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("graftty-bundle-layouts-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        // Flat SwiftPM bundle: resources at the root beside a `Resources`
        // directory, which Foundation reports as the bundle's resourceURL.
        let flat = temporary.appendingPathComponent("Flat.bundle")
        let deep = temporary.appendingPathComponent("Deep.bundle")
        for directory in [
            flat.appendingPathComponent("AgentPlugins"),
            flat.appendingPathComponent("Resources"),
            deep.appendingPathComponent("Contents/Resources/AgentPlugins"),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for bundleURL in [flat, deep] {
            let bundle = try #require(Bundle(url: bundleURL))
            let root = try #require(AgentPluginInstaller.bundledResourceRoot(in: bundle))
            #expect(fileManager.fileExists(atPath: root.path))
            #expect(root.lastPathComponent == "AgentPlugins")
        }
    }

    @Test("""
    @spec AGENT-6.45: When Graftty installs the team skill, the application shall state that each worktree has exactly one implementer, forbid creating worktrees through git, provider worktree tools, worktree-isolated subagents, or other skills, direct agents to delegate with graftty worktree add and an agent instead, and document graftty pane add with an agent for adding a non-editing reviewer or pair to an existing worktree, addressed by exact agent ID, or by runtime suffix only when no other agent of that runtime shares the worktree.
    """)
    func materializedTeamSkillForbidsManualWorktrees() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-worktree-rule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)
        for provider in ["codex", "claude"] {
            let skill = try String(contentsOf: destination.appendingPathComponent(
                "\(provider)/plugins/graftty/skills/graftty-team/SKILL.md"
            ))
            #expect(skill.contains("exactly one implementer"))
            #expect(!skill.contains("exactly one agent"))
            #expect(skill.contains("`git worktree add`"))
            #expect(skill.contains("worktree-isolated subagents"))
            #expect(skill.contains("graftty pane add <worktree> --agent <codex|claude> --prompt-stdin"))
            #expect(skill.contains("unless the implementer hands off"))
            #expect(skill.contains("<path>#<runtime>"))
            #expect(skill.contains("only when no other agent of that runtime shares the worktree"))
            let worktrees = try String(contentsOf: destination.appendingPathComponent(
                "\(provider)/plugins/graftty/skills/graftty-team/references/worktrees.md"
            ))
            #expect(worktrees.contains("--agent"))
            #expect(!worktrees.contains("no `--agent` or `--prompt-stdin`"))
        }
    }

    @Test("""
    @spec AGENT-6.43: When Graftty installs the recap skill, the application shall instruct agents not to mention the Attention report in their response to the user unless the report command fails.
    """)
    func materializedRecapSkillKeepsReportSilent() throws {
        for skill in try preparedSkillTexts(named: "graftty") {
            // Preserve this consequential response rule without pinning
            // surrounding explanatory prose or document organization.
            #expect(skill.contains("Do not mention the report in your response unless the command fails"))
            #expect(skill.contains("mention the failure in your final response"))
        }
    }

    @Test("Re-running prepare over an existing installation yields the full tree with no staging residue.")
    func rePreparingReplacesExistingInstallationWithoutStagingResidue() throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-replace-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: destination) }
        let installer = AgentPluginInstaller(
            grafttyCLIPath: "/Applications/Graftty.app/Contents/Helpers/graftty"
        )

        _ = try installer.prepare(destinationRoot: destination)
        // Plant a stale file inside the existing installation to prove the
        // replacement swaps in a complete fresh tree rather than merging.
        let staleMarker = destination
            .appendingPathComponent("codex/plugins/graftty/stale-marker")
        try Data().write(to: staleMarker)

        _ = try installer.prepare(destinationRoot: destination)

        #expect(!fileManager.fileExists(atPath: staleMarker.path))
        for provider in ["codex", "claude"] {
            #expect(fileManager.fileExists(atPath: destination
                .appendingPathComponent("\(provider)/plugins/graftty/skills/graftty-team/SKILL.md")
                .path))
            let hooks = try String(contentsOf: destination
                .appendingPathComponent("\(provider)/plugins/graftty/hooks/hooks.json"))
            #expect(hooks.contains("/Applications/Graftty.app/Contents/Helpers/graftty team hook"))
        }
        let residue = try fileManager.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".staging-") }
        #expect(residue.isEmpty)
    }

    @Test("A failed re-preparation preserves the existing marketplace installation intact.")
    func failedRePreparationPreservesExistingInstallation() throws {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-atomic-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: destination) }
        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)
        let codexHooks = destination
            .appendingPathComponent("codex/plugins/graftty/hooks/hooks.json")
        let hooksBeforeFailure = try String(contentsOf: codexHooks)

        // A source whose hooks.json cannot be parsed makes preparation fail
        // partway through materialization. The marketplace path stays
        // registered with the providers, so the previous tree must survive.
        let corruptSource = fileManager.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-corrupt-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: corruptSource) }
        for provider in ["codex", "claude"] {
            let hooksDirectory = corruptSource
                .appendingPathComponent("\(provider)/plugins/graftty/hooks", isDirectory: true)
            try fileManager.createDirectory(
                at: hooksDirectory,
                withIntermediateDirectories: true
            )
            try Data("not json".utf8)
                .write(to: hooksDirectory.appendingPathComponent("hooks.json"))
        }

        #expect(throws: (any Error).self) {
            try AgentPluginInstaller(resourceRoot: corruptSource)
                .prepare(destinationRoot: destination)
        }

        #expect(try String(contentsOf: codexHooks) == hooksBeforeFailure)
        #expect(fileManager.fileExists(atPath: destination
            .appendingPathComponent("codex/plugins/graftty/skills/graftty-team/SKILL.md")
            .path))
        let residue = try fileManager.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".staging-") }
        #expect(residue.isEmpty)
    }

    @Test("""
    @spec AGENT-6.14: If the user accepts the provider-plugin installation offer after preparation, then the application shall execute every provider-native marketplace and plugin installation step in displayed order, continue with the other provider after an individual failure, and report partial or complete success without requiring shell evaluation.
    """)
    func explicitInstallAttemptsEveryStructuredStepAndReportsFailures() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = try AgentPluginInstaller().prepare(destinationRoot: destination)
        let executor = RecordingPluginCLIExecutor(failingInvocation: 1)

        let report = await AgentPluginInstaller().install(
            plan,
            executor: executor,
            timeout: .seconds(1)
        )

        #expect(await executor.invocations() == plan.installSteps.map {
            Invocation(command: $0.executable, arguments: $0.arguments)
        })
        #expect(report.results.count == 5)
        #expect(report.results.map(\.succeeded) == [true, false, true, true, true])
        #expect(report.summary.contains("4 of 5"))
        #expect(report.summary.contains("Codex"))
    }
}

private struct Invocation: Equatable, Sendable {
    let command: String
    let arguments: [String]
}

private actor InventoryPluginCLIExecutor: CLIExecutor {
    private var inventories: [String: [String]]
    let failingMutation: Int?
    let codexConfigurationURL: URL?
    private var recorded: [Invocation] = []

    init(codex: String, claude: String, failingMutation: Int? = nil) {
        self.codexConfigurationURL = nil
        self.inventories = ["codex": [codex], "claude": [claude]]
        self.failingMutation = failingMutation
    }

    init(codexInventories: [String], claudeInventories: [String], failingMutation: Int? = nil, codexConfigurationURL: URL? = nil) {
        self.codexConfigurationURL = codexConfigurationURL
        self.inventories = ["codex": codexInventories, "claude": claudeInventories]
        self.failingMutation = failingMutation
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        let listing = args.prefix(2) == ["plugin", "list"]
        let output = inventories[command]?.first ?? "missing-cli"
        if listing, (inventories[command]?.count ?? 0) > 1 { inventories[command]?.removeFirst() }
        if listing, output == "missing-cli" { throw CLIError.notFound(command: command) }
        if !listing {
            recorded.append(Invocation(command: command, arguments: args))
            if recorded.count - 1 == failingMutation {
                throw CLIError.nonZeroExit(command: command, exitCode: 1, stderr: "fixture failure")
            }
        }
        if command == "codex", args == ["plugin", "remove", "graftty-team@graftty"], let codexConfigurationURL {
            try Data().write(to: codexConfigurationURL)
        }
        return CLIOutput(stdout: listing ? output : "updated", stderr: "", exitCode: 0)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }

    func mutations() -> [Invocation] { recorded }
}

private actor RecordingPluginCLIExecutor: CLIExecutor {
    private let failingInvocation: Int
    private var recorded: [Invocation] = []

    init(failingInvocation: Int) {
        self.failingInvocation = failingInvocation
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        let index = recorded.count
        recorded.append(Invocation(command: command, arguments: args))
        if index == failingInvocation {
            throw CLIError.nonZeroExit(command: command, exitCode: 1, stderr: "fixture failure")
        }
        return CLIOutput(stdout: "installed", stderr: "", exitCode: 0)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }

    func invocations() -> [Invocation] {
        recorded
    }
}
