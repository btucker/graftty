import Foundation

/// Writes the Graftty channel plugin's config into a plugins root directory.
/// Pure — the caller provides the manifest/template/cli-path; this module
/// just substitutes and writes. Idempotent (overwrites existing files).
public enum ChannelPluginInstaller {
    public static let pluginName = "graftty-channel"

    /// Install the plugin into `<pluginsRoot>/graftty-channel/`.
    /// - Parameters:
    ///   - pluginsRoot: Destination root (typically `~/.claude/plugins`).
    ///   - cliPath: Absolute path to the `graftty` binary; substituted for
    ///     `{{CLI_PATH}}` in `mcpTemplate`.
    ///   - manifest: Literal contents of `plugin.json`.
    ///   - mcpTemplate: Template for `.mcp.json` with `{{CLI_PATH}}` placeholder.
    public static func install(
        pluginsRoot: URL,
        cliPath: String,
        manifest: String,
        mcpTemplate: String
    ) throws {
        let dir = pluginsRoot.appendingPathComponent(pluginName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mcpRendered = mcpTemplate.replacingOccurrences(of: "{{CLI_PATH}}", with: cliPath)
        try mcpRendered.write(
            to: dir.appendingPathComponent(".mcp.json"),
            atomically: true, encoding: .utf8
        )
        try manifest.write(
            to: dir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )
    }

    /// Default plugins root: `~/.claude/plugins/`.
    public static func defaultPluginsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude").appendingPathComponent("plugins")
    }
}
