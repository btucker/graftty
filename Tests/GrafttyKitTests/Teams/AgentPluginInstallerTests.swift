import Foundation
import Testing
@testable import GrafttyKit

@Suite("Native agent plugin installer")
struct AgentPluginInstallerTests {
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
            #expect(skill.contains("<canonical-worktree-path>#<runtime>-<12hex>"))
            #expect(skill.contains("<canonical-worktree-path>#<runtime>"))
            #expect(skill.contains("display metadata and may be truncated"))
            #expect(skill.contains("Do not use provider-native agent messaging tools"))
            #expect(!skill.contains("## Trust boundary"))
            let hooks = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty-team/hooks/hooks.json"))
            #expect(hooks.components(separatedBy: "GRAFTTY_DISABLE_AGENT_HOOKS").count - 1 == 3)
            #expect(hooks.contains("/Applications/Graftty.app/Contents/Helpers/graftty team hook"))
        }
        let claudeManifest = try String(contentsOf: destination
            .appendingPathComponent("claude/plugins/graftty-team/.claude-plugin/plugin.json"))
        #expect(claudeManifest.contains(#""version": "0.2.0""#))
        let codexManifest = try String(contentsOf: destination
            .appendingPathComponent("codex/plugins/graftty-team/.codex-plugin/plugin.json"))
        #expect(codexManifest.contains(#""version": "0.2.0""#))
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
