import Foundation

/// Registers the `graftty-channel` MCP server at user scope via the
/// `claude mcp` subcommands (CHAN-4.1 through CHAN-4.5).
///
/// We delegate to `claude mcp add --scope user` rather than hand-writing
/// JSON because the only MCP-config locations Claude Code actually reads
/// are project-root `.mcp.json`, `~/.claude/settings[.local].json`, and
/// `~/.claude.json`'s top-level `mcpServers`. The previous implementation
/// wrote to `~/.claude/.mcp.json`, which Claude Code never consults — so
/// `claude mcp list` never surfaced the entry and channels were a silent
/// no-op. Going through the CLI keeps the canonical location concern out
/// of our code.
///
/// `claude mcp add` is not idempotent (re-invoking with the same name
/// exits 1 with "already exists"), so the install algorithm is
/// probe → compare → (remove + add if differs).
public enum ChannelMCPInstaller {
    public static let serverName = "graftty-channel"
    public static let mcpArgs: [String] = ["mcp-channel"]

    /// Register the `graftty-channel` server at user scope. Swallows
    /// subprocess errors via `NSLog` — channels failing to install is
    /// never fatal to app launch, and "Claude Code not installed" is a
    /// normal state.
    public static func install(executor: CLIExecutor, cliPath: String) async {
        let addArgs = ["mcp", "add", "--scope", "user", serverName, cliPath, "--"] + mcpArgs
        do {
            let existing = try await executor.capture(
                command: "claude",
                args: ["mcp", "get", serverName],
                at: "/"
            )
            if existing.exitCode == 0, currentStateMatches(output: existing.stdout, cliPath: cliPath) {
                return
            }
            if existing.exitCode == 0 {
                // Present but differs — remove first. Best-effort: the
                // existing entry might be at a different scope than user,
                // in which case remove returns non-zero. We don't care.
                _ = try? await executor.capture(
                    command: "claude",
                    args: ["mcp", "remove", serverName, "--scope", "user"],
                    at: "/"
                )
            }
        } catch CLIError.notFound {
            NSLog("[Graftty] Channels install skipped: `claude` CLI not on PATH")
            return
        } catch {
            NSLog("[Graftty] Channels mcp get failed: %@", String(describing: error))
            // Fall through to attempt add — a probe failure shouldn't block install.
        }

        do {
            _ = try await executor.capture(command: "claude", args: addArgs, at: "/")
        } catch CLIError.notFound {
            NSLog("[Graftty] Channels install skipped: `claude` CLI not on PATH")
        } catch {
            NSLog("[Graftty] Channels mcp add failed: %@", String(describing: error))
        }
    }

    /// Parse the indented lines `claude mcp get` emits and return true
    /// when Scope is User, Command matches `cliPath`, and Args match
    /// `mcpArgs`. Trims leading whitespace per line so a future tweak to
    /// Claude's indentation doesn't force a re-add on every launch.
    /// Returns false on any format change — a re-add is self-healing.
    static func currentStateMatches(output: String, cliPath: String) -> Bool {
        var scope: String?
        var command: String?
        var args: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let v = stripPrefix(trimmed, prefix: "Scope:") { scope = v }
            else if let v = stripPrefix(trimmed, prefix: "Command:") { command = v }
            else if let v = stripPrefix(trimmed, prefix: "Args:") { args = v }
        }
        guard let scope, scope.contains("User") else { return false }
        guard command == cliPath else { return false }
        return args == mcpArgs.joined(separator: " ")
    }

    private static func stripPrefix(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Remove any leftover `~/.claude/plugins/graftty-channel/` directory
    /// from prior versions that installed a plugin wrapper. Safe to call
    /// every launch — if the directory doesn't exist, this is a no-op.
    public static func removeLegacyPluginDirectory(pluginsRoot: URL) {
        let dir = pluginsRoot.appendingPathComponent("graftty-channel")
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Remove the now-abandoned `~/.claude/.mcp.json` written by the
    /// previous hand-rolled-JSON installer. Only deletes when the file's
    /// contents match the exact shape the old installer wrote (root is
    /// an object with the single key `mcpServers`, which contains only
    /// `graftty-channel`). If the user has repurposed the file for
    /// anything else, we leave it alone.
    public static func removeLegacyMCPConfigFile(path: URL) {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any],
              root.count == 1,
              let servers = root["mcpServers"] as? [String: Any],
              servers.count == 1,
              servers[serverName] != nil
        else { return }
        try? FileManager.default.removeItem(at: path)
    }

    /// Default legacy plugin root: `~/.claude/plugins/`.
    public static func defaultLegacyPluginsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude").appendingPathComponent("plugins")
    }

    /// Default legacy MCP config path: `~/.claude/.mcp.json`.
    public static func defaultLegacyMCPConfigPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude").appendingPathComponent(".mcp.json")
    }
}
