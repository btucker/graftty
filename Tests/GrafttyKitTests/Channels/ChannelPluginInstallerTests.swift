import XCTest
@testable import GrafttyKit

final class ChannelPluginInstallerTests: XCTestCase {
    func testInstallWritesMCPJSONWithSubstitutedPath() throws {
        let tmp = URL(fileURLWithPath: "/tmp/GrafttyChannelInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pluginsRoot = tmp.appendingPathComponent("plugins")
        let cliPath = "/Applications/Graftty.app/Contents/Resources/graftty"
        let manifest = #"{"name":"graftty-channel","version":"0.1.0"}"#
        let mcpTemplate = #"{"mcpServers":{"graftty-channel":{"command":"{{CLI_PATH}}","args":["mcp-channel"]}}}"#

        try ChannelPluginInstaller.install(
            pluginsRoot: pluginsRoot,
            cliPath: cliPath,
            manifest: manifest,
            mcpTemplate: mcpTemplate
        )

        let mcpJSON = try String(contentsOf: pluginsRoot
            .appendingPathComponent("graftty-channel")
            .appendingPathComponent(".mcp.json"))
        XCTAssertTrue(mcpJSON.contains(cliPath))
        XCTAssertFalse(mcpJSON.contains("{{CLI_PATH}}"))

        let pluginJSON = try String(contentsOf: pluginsRoot
            .appendingPathComponent("graftty-channel")
            .appendingPathComponent("plugin.json"))
        XCTAssertEqual(pluginJSON, manifest)
    }

    func testInstallIsIdempotent() throws {
        let tmp = URL(fileURLWithPath: "/tmp/GrafttyChannelInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pluginsRoot = tmp.appendingPathComponent("plugins")
        for _ in 0..<3 {
            try ChannelPluginInstaller.install(
                pluginsRoot: pluginsRoot,
                cliPath: "/x",
                manifest: "{}",
                mcpTemplate: "{}"
            )
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: pluginsRoot
            .appendingPathComponent("graftty-channel").path)
        XCTAssertEqual(Set(entries), Set([".mcp.json", "plugin.json"]))
    }

    func testUpdatedCliPathOverwritesPriorMCPJSON() throws {
        let tmp = URL(fileURLWithPath: "/tmp/GrafttyChannelInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pluginsRoot = tmp.appendingPathComponent("plugins")
        let template = #"{"mcpServers":{"graftty-channel":{"command":"{{CLI_PATH}}"}}}"#

        try ChannelPluginInstaller.install(
            pluginsRoot: pluginsRoot,
            cliPath: "/old/path/graftty",
            manifest: "{}",
            mcpTemplate: template
        )
        try ChannelPluginInstaller.install(
            pluginsRoot: pluginsRoot,
            cliPath: "/new/path/graftty",
            manifest: "{}",
            mcpTemplate: template
        )

        let mcpJSON = try String(contentsOf: pluginsRoot
            .appendingPathComponent("graftty-channel")
            .appendingPathComponent(".mcp.json"))
        XCTAssertTrue(mcpJSON.contains("/new/path/graftty"))
        XCTAssertFalse(mcpJSON.contains("/old/path/graftty"))
    }
}
