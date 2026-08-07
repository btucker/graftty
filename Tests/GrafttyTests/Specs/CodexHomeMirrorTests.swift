import Testing
import Foundation
@testable import GrafttyKit

@Suite("CodexHomeMirror — symlink farm and hooks merge")
struct CodexHomeMirrorTests {
    @Test("Symlinks every durable source entry and keeps hooks.json as the only generated override.")
    func symlinkFarmExcludesOnlyHooksOverride() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("auth.json"), "{}")
        try writeFile(src.appendingPathComponent("history.jsonl"), "")
        try writeFile(src.appendingPathComponent("hooks.json"), "{\"existing\": true}")
        try writeFile(src.appendingPathComponent("config.toml"), "")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sessions"), withIntermediateDirectories: true)

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let fm = FileManager.default

        // Symlinks for non-overridden entries.
        let authLink = dst.appendingPathComponent("auth.json")
        let resolved = try fm.destinationOfSymbolicLink(atPath: authLink.path)
        #expect(resolved.contains("auth.json"))

        let sessionsLink = dst.appendingPathComponent("sessions")
        let sessionsTarget = try? fm.destinationOfSymbolicLink(atPath: sessionsLink.path)
        #expect(sessionsTarget?.hasSuffix("sessions") == true)

        // Real files (not symlinks) for overrides.
        let hooks = dst.appendingPathComponent("hooks.json")
        let hooksTarget = try? fm.destinationOfSymbolicLink(atPath: hooks.path)
        #expect(hooksTarget == nil)  // Not a symlink.

        let config = dst.appendingPathComponent("config.toml")
        let configTarget = try fm.destinationOfSymbolicLink(atPath: config.path)
        #expect(configTarget == src.appendingPathComponent("config.toml").path)
    }

    @Test("@spec TEAM-IDLE-1.1: hooks.json is a union merge of user's existing hooks plus graftty's, identifying graftty entries by command-prefix sentinel.")
    func hooksUnionMerge() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("hooks.json"), """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "/path/to/user-script.sh" }] }
            ]
          }
        }
        """)

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let mergedData = try Data(contentsOf: dst.appendingPathComponent("hooks.json"))
        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        let hooks = merged["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        // User's matcher-group + graftty's = 2.
        #expect(sessionStart.count == 2)
        let commands = sessionStart.flatMap { group -> [String] in
            let handlers = (group["hooks"] as? [[String: Any]]) ?? []
            return handlers.compactMap { $0["command"] as? String }
        }
        #expect(commands.contains("/path/to/user-script.sh"))
        #expect(commands.contains(where: { $0.hasPrefix("/usr/local/bin/graftty team hook codex") }))

        // Re-running rebuild is idempotent (graftty entries strip-and-replace, not duplicate).
        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()
        let merged2Data = try Data(contentsOf: dst.appendingPathComponent("hooks.json"))
        let merged2 = try JSONSerialization.jsonObject(with: merged2Data) as! [String: Any]
        let hooks2 = merged2["hooks"] as! [String: Any]
        let sessionStart2 = hooks2["SessionStart"] as! [[String: Any]]
        #expect(sessionStart2.count == 2)
    }

    @Test("Codex mirror installs only the SessionStart graftty hook and removes stale graftty delivery hooks.")
    func grafttyHooksAreSessionStartOnly() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("hooks.json"), """
        {
          "hooks": {
            "PostToolUse": [
              { "hooks": [{ "type": "command", "command": "/usr/local/bin/graftty team hook codex post-tool-use" }] },
              { "hooks": [{ "type": "command", "command": "/path/to/user-post-tool-use.sh" }] }
            ],
            "Stop": [
              { "hooks": [{ "type": "command", "command": "/usr/local/bin/graftty team hook codex stop" }] }
            ]
          }
        }
        """)

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let mergedData = try Data(contentsOf: dst.appendingPathComponent("hooks.json"))
        let merged = try JSONSerialization.jsonObject(with: mergedData) as! [String: Any]
        let hooks = merged["hooks"] as! [String: Any]
        let sessionStartCommands = commands(in: hooks["SessionStart"] as! [[String: Any]])
        let postToolUseCommands = commands(in: hooks["PostToolUse"] as! [[String: Any]])
        let stopCommands = commands(in: hooks["Stop"] as! [[String: Any]])

        #expect(sessionStartCommands == ["/usr/local/bin/graftty team hook codex session-start"])
        #expect(postToolUseCommands == ["/path/to/user-post-tool-use.sh"])
        #expect(stopCommands.isEmpty)
    }

    @Test("""
    @spec TEAM-10.3: When Graftty synthesizes a managed CODEX_HOME, the application shall symlink `config.toml` to the user's durable Codex configuration so plugin, marketplace, and MCP mutations survive later mirror rebuilds.
    """)
    func configMutationsSurviveMirrorRebuilds() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("config.toml"), """
        model = "o3"
        """)

        let mirror = CodexHomeMirror(
            sourceDirectory: src,
            mirrorDirectory: dst,
            grafttyCLIPath: "/usr/local/bin/graftty"
        )
        try mirror.rebuild()

        let mirrorConfig = dst.appendingPathComponent("config.toml")
        let handle = try FileHandle(forWritingTo: mirrorConfig)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n[mcp_servers.runpod]\nurl = \"https://mcp.getrunpod.io/\"\n".utf8))
        try handle.close()

        try mirror.rebuild()

        let durable = try String(contentsOf: src.appendingPathComponent("config.toml"))
        let rebuilt = try String(contentsOf: mirrorConfig)
        #expect(durable.contains("[mcp_servers.runpod]"))
        #expect(rebuilt == durable)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mirrorConfig.path) == src.appendingPathComponent("config.toml").path)
    }

    @Test("Dangling symlinks (entries the user deleted) are pruned on rebuild.")
    func prunesDanglingSymlinks() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("foo.json"), "{}")
        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("foo.json").path))

        // User deletes foo.json; rebuild should remove the dangling symlink.
        try FileManager.default.removeItem(at: src.appendingPathComponent("foo.json"))
        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()
        // Note: fileExists follows symlinks, so even a dangling link returns false; check via isSymbolicLink resource value or path-existence.
        let dstFoo = dst.appendingPathComponent("foo.json")
        let resourceValues = try? dstFoo.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(resourceValues?.isSymbolicLink != true)
    }

    @Test("A missing durable config still receives a dangling mirror symlink for Codex to create through.")
    func missingConfigReceivesDurableSymlink() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        // No config.toml in src.

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let dstConfig = dst.appendingPathComponent("config.toml")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: dstConfig.path)
        #expect(target == src.appendingPathComponent("config.toml").path)
        #expect(!FileManager.default.fileExists(atPath: dstConfig.path))
    }

    private func makeMirrorSandbox() throws -> (URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-codex-mirror-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("src", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        return (src, dst)
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commands(in groups: [[String: Any]]) -> [String] {
        groups.flatMap { group -> [String] in
            let handlers = (group["hooks"] as? [[String: Any]]) ?? []
            return handlers.compactMap { $0["command"] as? String }
        }
    }
}
