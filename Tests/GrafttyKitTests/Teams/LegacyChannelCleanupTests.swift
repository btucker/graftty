import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec TEAM-8.1: When the application starts, the application shall best-effort run `claude mcp remove graftty-channel`, ignoring non-zero exit and logging failure.")
struct LegacyChannelCleanupTests {
    @Test func unregistersMCPServer() async {
        let exec = FakeCLIExecutor()
        exec.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel"],
            output: CLIOutput(stdout: "", stderr: "", exitCode: 0)
        )

        await LegacyChannelCleanup.unregisterMCPServer(executor: exec)

        let invokedArgs = exec.invocations.map(\.args)
        #expect(invokedArgs == [["mcp", "remove", "graftty-channel"]])
        #expect(exec.invocations.first?.command == "claude")
    }

    @Test func unregisterToleratesNonZeroExit() async {
        let exec = FakeCLIExecutor()
        exec.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel"],
            output: CLIOutput(stdout: "", stderr: "no such server", exitCode: 1)
        )

        // No throw; command was still attempted.
        await LegacyChannelCleanup.unregisterMCPServer(executor: exec)

        #expect(exec.invocations.count == 1)
    }

    @Test func unregisterToleratesMissingCLI() async {
        let exec = FakeCLIExecutor()
        exec.stub(
            command: "claude",
            args: ["mcp", "remove", "graftty-channel"],
            error: CLIError.notFound(command: "claude")
        )

        // No throw; logger absorbs it.
        await LegacyChannelCleanup.unregisterMCPServer(executor: exec)

        #expect(exec.invocations.count == 1)
    }
}

private func makeLegacyTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("legacyCleanup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("@spec TEAM-8.2: When the application starts, the application shall delete `~/.claude/.mcp.json` if it exists and contains no MCP server entries other than `graftty-channel`.")
struct LegacyMCPConfigCleanupTests {
    @Test func deletesIfOnlyGrafttyChannel() throws {
        let dir = try makeLegacyTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".mcp.json")
        let payload: [String: Any] = [
            "mcpServers": [
                "graftty-channel": ["command": "/opt/graftty", "args": ["mcp-channel"]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: path)

        LegacyChannelCleanup.removeLegacyMCPConfigFile(at: path)

        #expect(FileManager.default.fileExists(atPath: path.path) == false)
    }

    @Test func preservesIfOtherServersPresent() throws {
        let dir = try makeLegacyTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".mcp.json")
        let payload: [String: Any] = [
            "mcpServers": [
                "graftty-channel": ["command": "/opt/graftty"],
                "other-server": ["command": "/opt/other"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: path)

        LegacyChannelCleanup.removeLegacyMCPConfigFile(at: path)

        #expect(FileManager.default.fileExists(atPath: path.path) == true)
    }

    @Test func preservesIfExtraRootKeys() throws {
        let dir = try makeLegacyTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".mcp.json")
        let payload: [String: Any] = [
            "mcpServers": [
                "graftty-channel": ["command": "/opt/graftty"],
            ],
            "userEdit": "keep-me",
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: path)

        LegacyChannelCleanup.removeLegacyMCPConfigFile(at: path)

        #expect(FileManager.default.fileExists(atPath: path.path) == true)
    }

    @Test func noOpIfFileAbsent() throws {
        let dir = try makeLegacyTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".mcp.json")
        // File not created.

        LegacyChannelCleanup.removeLegacyMCPConfigFile(at: path)

        #expect(FileManager.default.fileExists(atPath: path.path) == false)
    }
}

@Suite("@spec TEAM-8.3: When the application starts, the application shall delete `~/.claude/plugins/graftty-channel` if present.")
struct LegacyPluginDirectoryCleanupTests {
    @Test func deletesIfPresent() throws {
        let pluginsRoot = try makeLegacyTempDir()
        defer { try? FileManager.default.removeItem(at: pluginsRoot) }
        let dir = pluginsRoot.appendingPathComponent("graftty-channel")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(
            to: dir.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        LegacyChannelCleanup.removeLegacyPluginDirectory(pluginsRoot: pluginsRoot)

        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test func noOpIfAbsent() throws {
        let pluginsRoot = try makeLegacyTempDir()
        defer { try? FileManager.default.removeItem(at: pluginsRoot) }
        // Don't create graftty-channel/.
        LegacyChannelCleanup.removeLegacyPluginDirectory(pluginsRoot: pluginsRoot)
        // Pass condition: no crash.
    }
}

@Suite("@spec TEAM-8.4: When the application starts, if `defaultCommand` contains `--dangerously-load-development-channels server:graftty-channel`, the application shall strip the substring (with any adjacent leading whitespace), write the cleaned value back to `defaultCommand`, and present a one-shot informational `NSAlert` describing the change.")
struct DefaultCommandScrubTests {
    private func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    @Test func scrubRemovesFlagAtEnd() {
        let defaults = ephemeralDefaults()
        defaults.set(
            "claude --dangerously-load-development-channels server:graftty-channel",
            forKey: "defaultCommand"
        )

        let didStrip = LegacyChannelCleanup.scrubDefaultCommandLaunchFlag(in: defaults)

        #expect(didStrip == true)
        #expect(defaults.string(forKey: "defaultCommand") == "claude")
    }

    @Test func scrubRemovesFlagInMiddle() {
        let defaults = ephemeralDefaults()
        defaults.set(
            "claude --dangerously-load-development-channels server:graftty-channel --resume",
            forKey: "defaultCommand"
        )

        let didStrip = LegacyChannelCleanup.scrubDefaultCommandLaunchFlag(in: defaults)

        #expect(didStrip == true)
        #expect(defaults.string(forKey: "defaultCommand") == "claude --resume")
    }

    @Test func scrubNoOpWhenFlagAbsent() {
        let defaults = ephemeralDefaults()
        defaults.set("claude", forKey: "defaultCommand")

        let didStrip = LegacyChannelCleanup.scrubDefaultCommandLaunchFlag(in: defaults)

        #expect(didStrip == false)
        #expect(defaults.string(forKey: "defaultCommand") == "claude")
    }

    @Test func scrubNoOpWhenKeyUnset() {
        let defaults = ephemeralDefaults()

        let didStrip = LegacyChannelCleanup.scrubDefaultCommandLaunchFlag(in: defaults)

        #expect(didStrip == false)
    }
}
