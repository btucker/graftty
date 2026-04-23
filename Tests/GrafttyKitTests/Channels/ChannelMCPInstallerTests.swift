import XCTest
@testable import GrafttyKit

final class ChannelMCPInstallerTests: XCTestCase {
    private let cliPath = "/Applications/Graftty.app/Contents/Helpers/graftty"

    private func matchingGetOutput(command: String, scope: String = "User config (available in all your projects)") -> String {
        """
        graftty-channel:
          Scope: \(scope)
          Status: ✓ Connected
          Type: stdio
          Command: \(command)
          Args: mcp-channel
          Environment:

        """
    }

    private func makeTempDir() -> URL {
        let tmp = URL(fileURLWithPath: "/tmp/GrafttyChannelMCPTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - install

    func testInstallCallsMcpAddWhenEntryAbsent() async {
        let runner = FakeCLIExecutor()
        runner.stub(
            command: "claude",
            args: ["mcp", "get", "graftty-channel"],
            output: CLIOutput(
                stdout: "",
                stderr: "No MCP server found with name: \"graftty-channel\".",
                exitCode: 1
            )
        )
        runner.stub(
            command: "claude",
            args: ["mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel"],
            output: CLIOutput(stdout: "Added server graftty-channel", stderr: "", exitCode: 0)
        )

        await ChannelMCPInstaller.install(executor: runner, cliPath: cliPath)

        let invokedArgs = runner.invocations.map(\.args)
        XCTAssertTrue(invokedArgs.contains([
            "mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel",
        ]))
        // remove should not be called when entry is absent.
        XCTAssertFalse(invokedArgs.contains { $0.starts(with: ["mcp", "remove"]) })
    }

    func testInstallSkipsWhenCurrentStateMatches() async {
        let runner = FakeCLIExecutor()
        runner.stub(
            command: "claude",
            args: ["mcp", "get", "graftty-channel"],
            output: CLIOutput(
                stdout: matchingGetOutput(command: cliPath),
                stderr: "",
                exitCode: 0
            )
        )

        await ChannelMCPInstaller.install(executor: runner, cliPath: cliPath)

        // Only the probe — no add, no remove.
        XCTAssertEqual(runner.invocations.map(\.args), [["mcp", "get", "graftty-channel"]])
    }

    func testInstallReplacesOnCliPathChange() async {
        let runner = FakeCLIExecutor()
        runner.stub(
            command: "claude",
            args: ["mcp", "get", "graftty-channel"],
            output: CLIOutput(
                stdout: matchingGetOutput(command: "/old/path/graftty"),
                stderr: "",
                exitCode: 0
            )
        )
        runner.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel", "--scope", "user"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )
        runner.stub(
            command: "claude",
            args: ["mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )

        await ChannelMCPInstaller.install(executor: runner, cliPath: cliPath)

        let invokedArgs = runner.invocations.map(\.args)
        XCTAssertTrue(invokedArgs.contains(["mcp", "remove", "graftty-channel", "--scope", "user"]))
        XCTAssertTrue(invokedArgs.contains([
            "mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel",
        ]))
    }

    func testInstallReplacesWhenScopeMismatches() async {
        let runner = FakeCLIExecutor()
        runner.stub(
            command: "claude",
            args: ["mcp", "get", "graftty-channel"],
            output: CLIOutput(
                stdout: matchingGetOutput(command: cliPath, scope: "Local config"),
                stderr: "",
                exitCode: 0
            )
        )
        runner.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel", "--scope", "user"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )
        runner.stub(
            command: "claude",
            args: ["mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )

        await ChannelMCPInstaller.install(executor: runner, cliPath: cliPath)

        let invokedArgs = runner.invocations.map(\.args)
        XCTAssertTrue(invokedArgs.contains(["mcp", "remove", "graftty-channel", "--scope", "user"]))
        XCTAssertTrue(invokedArgs.contains([
            "mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel",
        ]))
    }

    func testInstallSilentlyNoOpsWhenClaudeNotInstalled() async {
        let runner = FakeCLIExecutor()
        runner.stub(
            command: "claude",
            args: ["mcp", "get", "graftty-channel"],
            error: CLIError.notFound(command: "claude")
        )

        await ChannelMCPInstaller.install(executor: runner, cliPath: cliPath)

        // Only the probe; nothing else attempted after notFound.
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testInstallSwallowsAddFailure() async {
        let runner = FakeCLIExecutor()
        runner.stub(
            command: "claude",
            args: ["mcp", "get", "graftty-channel"],
            output: CLIOutput(stdout: "", stderr: "not found", exitCode: 1)
        )
        runner.stub(
            command: "claude",
            args: ["mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel"],
            output: CLIOutput(stdout: "", stderr: "boom", exitCode: 1)
        )

        // Must not throw or crash.
        await ChannelMCPInstaller.install(executor: runner, cliPath: cliPath)

        let invokedArgs = runner.invocations.map(\.args)
        XCTAssertTrue(invokedArgs.contains([
            "mcp", "add", "--scope", "user", "graftty-channel", cliPath, "--", "mcp-channel",
        ]))
    }

    // MARK: - removeLegacyMCPConfigFile(path:)

    func testRemoveLegacyMCPConfigFile_RemovesWhenOldShape() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent(".mcp.json")
        let payload: [String: Any] = [
            "mcpServers": [
                "graftty-channel": ["command": "/opt/graftty", "args": ["mcp-channel"]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: target)

        ChannelMCPInstaller.removeLegacyMCPConfigFile(path: target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRemoveLegacyMCPConfigFile_PreservesUserEdits() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Case 1: extra key at document root.
        let withExtraRootKey = tmp.appendingPathComponent("extra-root.mcp.json")
        let payload1: [String: Any] = [
            "mcpServers": [
                "graftty-channel": ["command": "/opt/graftty", "args": ["mcp-channel"]],
            ],
            "userEdit": "keep-me",
        ]
        try JSONSerialization.data(withJSONObject: payload1).write(to: withExtraRootKey)

        ChannelMCPInstaller.removeLegacyMCPConfigFile(path: withExtraRootKey)

        XCTAssertTrue(FileManager.default.fileExists(atPath: withExtraRootKey.path))

        // Case 2: extra entry under mcpServers.
        let withExtraServer = tmp.appendingPathComponent("extra-server.mcp.json")
        let payload2: [String: Any] = [
            "mcpServers": [
                "graftty-channel": ["command": "/opt/graftty", "args": ["mcp-channel"]],
                "other-tool": ["command": "/opt/other"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload2).write(to: withExtraServer)

        ChannelMCPInstaller.removeLegacyMCPConfigFile(path: withExtraServer)

        XCTAssertTrue(FileManager.default.fileExists(atPath: withExtraServer.path))
    }

    func testRemoveLegacyMCPConfigFile_NoOpWhenAbsent() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let absent = tmp.appendingPathComponent("does-not-exist.mcp.json")

        // Must not throw / crash.
        ChannelMCPInstaller.removeLegacyMCPConfigFile(path: absent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    // MARK: - removeLegacyPluginDirectory(pluginsRoot:) — unchanged behavior

    func testRemoveLegacyPluginDirectoryRemovesItWhenPresent() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pluginsRoot = tmp.appendingPathComponent("plugins")
        let dir = pluginsRoot.appendingPathComponent("graftty-channel")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(
            to: dir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )

        ChannelMCPInstaller.removeLegacyPluginDirectory(pluginsRoot: pluginsRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testRemoveLegacyPluginDirectoryIsNoOpWhenAbsent() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Should not throw; nothing to assert beyond "no crash / exception".
        ChannelMCPInstaller.removeLegacyPluginDirectory(
            pluginsRoot: tmp.appendingPathComponent("nonexistent")
        )
    }
}
