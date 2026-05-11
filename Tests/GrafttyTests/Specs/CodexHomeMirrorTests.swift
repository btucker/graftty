import Testing
import Foundation
@testable import GrafttyKit

@Suite("CodexHomeMirror — symlink farm and config merge")
struct CodexHomeMirrorTests {
    @Test("Symlinks every entry in source dir except hooks.json and config.toml.")
    func symlinkFarmExcludesOverrides() throws {
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

    @Test("config.toml gains [features].hooks=true while preserving other keys.")
    func configFeatureFlagMerge() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        try writeFile(src.appendingPathComponent("config.toml"), """
        model = "o3"

        [features]
        some_other_feature = true
        """)

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let merged = try String(contentsOf: dst.appendingPathComponent("config.toml"))
        #expect(merged.contains("\nhooks = true"))
        #expect(!merged.contains("codex_hooks"))
        #expect(merged.contains("model = \"o3\""))
        #expect(merged.contains("some_other_feature = true"))
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

    @Test("config.toml is created fresh when source has none.")
    func configCreatedWhenMissing() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        // No config.toml in src.

        try CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst, grafttyCLIPath: "/usr/local/bin/graftty").rebuild()

        let dstConfig = dst.appendingPathComponent("config.toml")
        let contents = try String(contentsOf: dstConfig)
        #expect(contents.contains("[features]"))
        #expect(contents.contains("\nhooks = true"))
        #expect(!contents.contains("codex_hooks"))
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
}
