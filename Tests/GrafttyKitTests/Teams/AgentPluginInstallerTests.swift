import Foundation
import Testing
@testable import GrafttyKit

@Suite("Native agent plugin installer")
struct AgentPluginInstallerTests {
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
                    "\(provider)/plugins/graftty-team/.\(provider)-plugin/plugin.json"
                ))
                let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(manifest["version"] as? String == version)
                #expect(manifest["name"] as? String == "graftty-team")
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
        let installer = AgentPluginInstaller()
        let plan = try installer.prepare(destinationRoot: destination)
        let codex = #"{"installed":[{"pluginId":"graftty-team@graftty","installed":true,"enabled":true}]}"#
        let claude = #"[{"id":"graftty-team@graftty","scope":"user","enabled":true}]"#

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
            (codex.replacingOccurrences(of: "graftty-team@graftty", with: "other@graftty"),
             claude.replacingOccurrences(of: "graftty-team@graftty", with: "other@graftty")),
        ] {
            let optedOut = InventoryPluginCLIExecutor(codex: codexInventory, claude: claudeInventory)
            #expect(await installer.refresh(plan, executor: optedOut).succeeded)
            #expect(await optedOut.mutations().isEmpty)
        }

        for invalid in ["not JSON", "{}", #"{"installed":[{"pluginId":"graftty-team@graftty"}]}"#, "missing-cli"] {
            let broken = InventoryPluginCLIExecutor(codex: invalid, claude: claude)
            let failed = await installer.refresh(plan, executor: broken)
            #expect(!failed.succeeded)
            #expect(failed.results.first?.step.provider == .codex)
            #expect(failed.results.first?.succeeded == false)
            #expect(await broken.mutations().map(\.command) == ["claude", "claude"])
        }
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
            at: GrafttyKitResourceBundle.bundle.bundleURL.appendingPathComponent("AgentPlugins"),
            to: source
        )
        let claudeRoot = source.appendingPathComponent("claude/plugins/graftty-team")
        let links = [
            "skills/graftty-team/SKILL.md": "../../../../../codex/plugins/graftty-team/skills/graftty-team/SKILL.md",
            "skills/graftty-open/SKILL.md": "../../../../../codex/plugins/graftty-team/skills/graftty-open/SKILL.md",
            ".claude-plugin/plugin.json": "../../../../codex/plugins/graftty-team/.codex-plugin/plugin.json",
        ]
        for (path, target) in links {
            let link = claudeRoot.appendingPathComponent(path)
            try fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        let expectedSkill = try Data(contentsOf: claudeRoot
            .appendingPathComponent("skills/graftty-team/SKILL.md"))
        let expectedOpenSkill = try Data(contentsOf: claudeRoot
            .appendingPathComponent("skills/graftty-open/SKILL.md"))
        let expectedManifest = try Data(contentsOf: claudeRoot
            .appendingPathComponent(".claude-plugin/plugin.json"))
        let destination = temporary.appendingPathComponent("prepared")
        _ = try AgentPluginInstaller(resourceRoot: source).prepare(destinationRoot: destination)

        for provider in ["codex", "claude"] {
            try fileManager.copyItem(
                at: destination.appendingPathComponent("\(provider)/plugins/graftty-team"),
                to: temporary.appendingPathComponent("cached-\(provider)")
            )
        }
        try fileManager.removeItem(at: source)
        try fileManager.removeItem(at: destination)

        for provider in ["codex", "claude"] {
            let cached = temporary.appendingPathComponent("cached-\(provider)")
            for (path, expected) in [
                "skills/graftty-team/SKILL.md": expectedSkill,
                "skills/graftty-open/SKILL.md": expectedOpenSkill,
                ".\(provider)-plugin/plugin.json": expectedManifest,
            ] {
                let file = cached.appendingPathComponent(path)
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                #expect(attributes[.type] as? FileAttributeType == .typeRegular)
                #expect(try Data(contentsOf: file) == expected)
            }
        }
    }

    @Test("""
    @spec AGENT-6.33: When Graftty prepares provider plugins, the application shall bundle a `graftty-open` skill for both providers that explains when to offer host files or URLs, how the caller's worktree scopes the offer, and the mobile preview's limits and user action.
    """)
    func preparesOpenSkillForBothProviders() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-open-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)

        for provider in ["codex", "claude"] {
            let file = destination.appendingPathComponent(
                "\(provider)/plugins/graftty-team/skills/graftty-open/SKILL.md"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attributes[.type] as? FileAttributeType == .typeRegular)
            let skill = try String(contentsOf: file, encoding: .utf8)
            #expect(skill.contains("name: graftty-open"))
            #expect(skill.contains("graftty open"))
            #expect(skill.contains("tracked worktree"))
            #expect(skill.contains("20 MB"))
            #expect(skill.contains("15 minutes"))
            #expect(skill.contains("Open menu"))
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
                .appendingPathComponent("plugins/graftty-team/hooks/hooks.json"))
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
    @spec AGENT-6.10: When the user prepares native agent integration, the application shall materialize validated Codex and Claude marketplace snapshots containing the shared `graftty-team` skill and lifecycle hooks that use the bundled CLI and honor the hook opt-out, then present provider-native install and update commands without silently changing provider trust configuration.
    """)
    func preparesBothProviderMarketplacesAndCommands() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = try AgentPluginInstaller(
            grafttyCLIPath: "/Applications/Graftty.app/Contents/Helpers/graftty"
        ).prepare(destinationRoot: destination)

        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent("codex/plugins/graftty-team/skills/graftty-team/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent("claude/plugins/graftty-team/skills/graftty-team/SKILL.md").path))
        #expect(try String(contentsOf: destination
            .appendingPathComponent("codex/plugins/graftty-team/hooks/hooks.json"))
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
            "plugin", "install", "graftty-team@graftty", "--scope", "user",
        ])
        #expect(plan.installSteps[4].arguments == [
            "plugin", "update", "graftty-team@graftty", "--scope", "user",
        ])
        for provider in ["codex", "claude"] {
            let skill = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty-team/skills/graftty-team/SKILL.md"))
            #expect(skill.contains("<graftty-peer-message agent=\"<exact-address>\" fallback-agent=\"<runtime-address>\">"))
            #expect(skill.contains("<graftty-forge-message provider=\"<provider>\">"))
            #expect(skill.contains("<graftty-system-message>"))
            #expect(skill.contains("<canonical-worktree-path>#<runtime>-<12hex>"))
            #expect(skill.contains("<canonical-worktree-path>#<runtime>"))
            #expect(skill.contains("display metadata and may be truncated"))
            #expect(skill.contains("Do not use provider-native agent messaging tools"))
            #expect(skill.contains("graftty team reply '<message-id>' --stdin"))
            #expect(skill.contains("takes precedence over conflicting reply paths"))
            #expect(skill.contains("--fallback"))
            #expect(!skill.contains("## Trust boundary"))
            let hooks = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty-team/hooks/hooks.json"))
            let expectedHookCount = provider == "claude" ? 7 : 5
            #expect(hooks.components(separatedBy: "GRAFTTY_DISABLE_AGENT_HOOKS").count - 1 == expectedHookCount)
            #expect(hooks.contains("/Applications/Graftty.app/Contents/Helpers/graftty team hook"))
        }
        let claudeManifest = try String(contentsOf: destination
            .appendingPathComponent("claude/plugins/graftty-team/.claude-plugin/plugin.json"))
        #expect(claudeManifest.contains(#""version": "0.3.2""#))
        let codexManifest = try String(contentsOf: destination
            .appendingPathComponent("codex/plugins/graftty-team/.codex-plugin/plugin.json"))
        #expect(codexManifest.contains(#""version": "0.3.2""#))
    }

    @Test("""
    @spec AGENT-6.21: When Graftty materializes a provider team skill, the skill shall explain the durable hierarchical `.graftty/**/GRAFTTY.md` instruction system's repository and worktree scopes, its `## Private` sharing boundary, next-session delivery, and the authorization required before editing an instruction file.
    """)
    func materializedSkillsExplainDurableInstructionFiles() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugin-instructions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)

        for provider in ["codex", "claude"] {
            let skill = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty-team/skills/graftty-team/SKILL.md"))
            #expect(skill.contains("## Durable agent instructions"))
            #expect(skill.contains("`.graftty/GRAFTTY.md`"))
            #expect(skill.contains("`.graftty/<parent>/GRAFTTY.md`"))
            #expect(skill.contains("`.graftty/<parent>/<leaf>/GRAFTTY.md`"))
            #expect(skill.contains("`## Private`"))
            #expect(skill.contains("next session start"))
            #expect(skill.contains("only when authorized"))
        }
    }

    @Test("""
    @spec AGENT-6.26: When Graftty materializes a provider team skill, the skill shall direct an agent to proactively delegate suitable independent work by launching a new top-level agent with `graftty worktree add --agent --prompt-stdin`, distinguish delegation from creating a worktree alone, require the parent to confirm child reachability before relinquishing the delegated scope, and preserve the user's authorization boundaries.
    """)
    func materializedSkillsExplainRealWorktreeDelegation() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugin-delegation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)

        for provider in ["codex", "claude"] {
            let skill = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty-team/skills/graftty-team/SKILL.md"))
            #expect(skill.contains("## Delegate work into a new worktree"))
            #expect(skill.contains("Proactively delegate"))
            #expect(skill.contains(
                "graftty worktree add <name> --agent <codex|claude> --prompt-stdin"
            ))
            #expect(skill.contains("does not delegate the task"))
            #expect(skill.contains("confirm that a top-level child"))
            #expect(skill.contains("Once reachable, stop working on that scope"))
            #expect(skill.contains("parent's exact canonical address"))
            #expect(skill.contains("Parent fallback address: <parent-runtime-address>"))
            #expect(skill.contains("does not grant new authority"))
        }
    }

    @Test("""
    @spec AGENT-6.16: While a provider sandbox denies a `graftty team` command access to a live Graftty control socket with `EPERM` or `errno 1`, the installed team skill shall instruct the agent to verify the socket and owner read-only, retry the same command with narrowly scoped elevated permission, and avoid deleting or recreating the socket or restarting Graftty as a first response.
    """)
    func materializedSkillsDiagnoseSandboxDeniedControlSocket() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugin-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try AgentPluginInstaller().prepare(destinationRoot: destination)

        for provider in ["codex", "claude"] {
            let skill = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty-team/skills/graftty-team/SKILL.md"))
            #expect(skill.contains("`EPERM` or `errno 1`"))
            #expect(skill.contains("read-only checks"))
            #expect(skill.contains("narrowly scoped elevated permission"))
            #expect(skill.contains("Do not delete or recreate the socket"))
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
            .appendingPathComponent("codex/plugins/graftty-team/stale-marker")
        try Data().write(to: staleMarker)

        _ = try installer.prepare(destinationRoot: destination)

        #expect(!fileManager.fileExists(atPath: staleMarker.path))
        for provider in ["codex", "claude"] {
            #expect(fileManager.fileExists(atPath: destination
                .appendingPathComponent("\(provider)/plugins/graftty-team/skills/graftty-team/SKILL.md")
                .path))
            let hooks = try String(contentsOf: destination
                .appendingPathComponent("\(provider)/plugins/graftty-team/hooks/hooks.json"))
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
            .appendingPathComponent("codex/plugins/graftty-team/hooks/hooks.json")
        let hooksBeforeFailure = try String(contentsOf: codexHooks)

        // A source whose hooks.json cannot be parsed makes preparation fail
        // partway through materialization. The marketplace path stays
        // registered with the providers, so the previous tree must survive.
        let corruptSource = fileManager.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-corrupt-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: corruptSource) }
        for provider in ["codex", "claude"] {
            let hooksDirectory = corruptSource
                .appendingPathComponent("\(provider)/plugins/graftty-team/hooks", isDirectory: true)
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
            .appendingPathComponent("codex/plugins/graftty-team/skills/graftty-team/SKILL.md")
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
    let codex: String
    let claude: String
    private var recorded: [Invocation] = []

    init(codex: String, claude: String) {
        self.codex = codex
        self.claude = claude
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        let listing = args.prefix(2) == ["plugin", "list"]
        let output = command == "codex" ? codex : claude
        if listing, output == "missing-cli" { throw CLIError.notFound(command: command) }
        if !listing { recorded.append(Invocation(command: command, arguments: args)) }
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
