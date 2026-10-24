import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct DevContainerMCPTests {
    @Test("@spec REMOTE-30.16: When preparing MCP mounts through Dev Container CLI, the application shall preserve project configuration and relative path resolution, supply read-only mounts through a private configuration override, and remove that override after success or failure.", arguments: [false, true])
    func preparesMCPOnlyAfterBridgeCompatibilityCheck(missingRuntime: Bool) async throws {
        let fixture = try SkillFixture(); defer { fixture.remove() }
        try fixture.write("home/.agents/skills/personal/SKILL.md", "personal")
        try fixture.write("workspace/.devcontainer/devcontainer.json", #"{"image":"fixture"}"#)
        let workspace = fixture.root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let owner = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let scope = MCPProxyScope(grantID: UUID(), generation: 1, repositoryID: UUID(), worktreePath: workspace.path, serverID: "fixture")
        let mcp = MCPProfileMount(directory: "/scoped/socket", runtime: "/host/runtime", configurations: [.init(parent: owner, scope: scope)])
        let executor = MCPContainerExecutor(home: fixture.root.appendingPathComponent("home"), workspace: workspace, missingRuntime: missingRuntime)
        let profiles = fixture.root.appendingPathComponent("profiles")
        let operation = UUID()
        let preparer = DevContainerPreparer(executor: executor, profileDirectory: profiles)
        if missingRuntime {
            await #expect(throws: (any Error).self) {
                _ = try await preparer.prepare(workspace: workspace.path, operationID: operation, skills: [fixture.capture()], mcp: mcp)
            }
            #expect(await executor.inner.commands.allSatisfy { $0.last?.contains("codex-mcp.toml") != true })
        } else {
            let prepared = try await preparer.prepare(workspace: workspace.path, operationID: operation, skills: [fixture.capture()], mcp: mcp)
            #expect(prepared.mcpConfigured == true && !prepared.agentReady)
            let profile = try #require(prepared.agentSkillHome)
            #expect(FileManager.default.fileExists(atPath: profile + "/.codex/config.toml"))
            #expect(FileManager.default.fileExists(atPath: profile + "/.claude/.claude.json"))
            #expect(try JSONDecoder().decode(PreparedDevContainer.self, from: JSONEncoder().encode(prepared)) == prepared)
            let up = try #require(await executor.inner.commands.first { $0.first == "up" })
            #expect(!up.contains(where: { $0.contains(",readonly") }))
            #expect(up.contains(CanonicalPath.canonicalize(workspace.path) + "/.devcontainer/devcontainer.json"))
        }
        let override = try #require(await executor.overrideData)
        let configuration = try #require(JSONSerialization.jsonObject(with: override) as? [String: Any])
        #expect(configuration["mounts"] as? [String] == ["type=volume,source=cache,target=/cache", "type=bind,source=/scoped/socket,target=/run/graftty-mcp,readonly", "type=bind,source=/host/runtime,target=/opt/graftty-mcp,readonly"])
        #expect((configuration["build"] as? [String: String])?["dockerfile"] == "../Dockerfile")
        #expect(configuration["postCreateCommand"] as? String == "echo project")
        #expect(configuration["configFilePath"] == nil)
        let path = try #require(await executor.overridePath)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try String(contentsOf: workspace.appendingPathComponent(".devcontainer/devcontainer.json"), encoding: .utf8) == #"{"image":"fixture"}"#)
    }
}

private actor MCPContainerExecutor: CLIExecutor {
    nonisolated let inner: SkillContainerExecutor
    let missingRuntime: Bool
    var overrideData: Data?
    var overridePath: String?
    init(home: URL, workspace: URL, missingRuntime: Bool) {
        inner = SkillContainerExecutor(home: home, workspace: workspace); self.missingRuntime = missingRuntime
    }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        if args.first == "read-configuration" {
            return .init(stdout: #"{"configuration":{"build":{"dockerfile":"../Dockerfile"},"postCreateCommand":"echo project","mounts":["type=volume,source=cache,target=/cache"],"configFilePath":{"scheme":"file"}}}"#, stderr: "", exitCode: 0)
        }
        if args.first == "up", let index = args.firstIndex(of: "--override-config") {
            overridePath = args[index + 1]
            overrideData = try Data(contentsOf: URL(fileURLWithPath: args[index + 1]))
        }
        if args.last?.contains("/opt/graftty-mcp/bin/graftty remote mcp bridge --help") == true {
            return .init(stdout: "", stderr: "", exitCode: missingRuntime ? 127 : 0)
        }
        return try await inner.run(command: command, args: args, at: directory)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}
