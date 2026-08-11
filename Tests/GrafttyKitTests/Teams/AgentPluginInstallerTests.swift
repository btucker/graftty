import Foundation
import Testing
@testable import GrafttyKit

@Suite("Native agent plugin installer")
struct AgentPluginInstallerTests {
    @Test("""
    @spec AGENT-6.10: When the user prepares native agent integration, the application shall materialize validated Codex and Claude marketplace snapshots containing the shared `graftty-team` skill and skill-managed lifecycle hooks, then present provider-native install commands without silently changing provider trust configuration.
    """)
    func preparesBothProviderMarketplacesAndCommands() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = try AgentPluginInstaller().prepare(destinationRoot: destination)

        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent("codex/plugins/graftty-team/skills/graftty-team/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent("claude/plugins/graftty-team/skills/graftty-team/SKILL.md").path))
        #expect(try String(contentsOf: destination
            .appendingPathComponent("codex/plugins/graftty-team/hooks/hooks.json"))
            .contains("--skill-managed"))
        #expect(plan.commands.count == 4)
        #expect(plan.commands[0].contains("codex plugin marketplace add"))
        #expect(plan.commands[2].contains("claude plugin marketplace add"))
        #expect(plan.installSteps.map(\.provider) == [.codex, .codex, .claude, .claude])
        #expect(plan.installSteps[0].arguments == ["plugin", "marketplace", "add", destination
            .appendingPathComponent("codex", isDirectory: true).path])
        for provider in ["codex", "claude"] {
            let skill = try String(contentsOf: destination
                .appendingPathComponent(provider)
                .appendingPathComponent("plugins/graftty-team/skills/graftty-team/SKILL.md"))
            #expect(skill.contains("<graftty-peer-message agent=\"<address>\">"))
            #expect(skill.contains("<canonical-worktree-path>#<runtime>-<12hex>"))
            #expect(!skill.contains("## Trust boundary"))
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
        #expect(report.results.count == 4)
        #expect(report.results.map(\.succeeded) == [true, false, true, true])
        #expect(report.summary.contains("3 of 4"))
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
