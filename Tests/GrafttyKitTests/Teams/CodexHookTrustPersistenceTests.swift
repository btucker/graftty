import Foundation
import Testing
@testable import GrafttyKit

@Suite("Codex hook trust persistence")
struct CodexHookTrustPersistenceTests {
    @Test("""
    @spec TEAM-10.24: When Graftty refreshes a managed Codex config, the application shall retain hook trust hashes and enablement saved in that managed home, refresh other settings from the durable config, and leave the durable config unchanged.
    """, arguments: [false, true])
    func managedHookDecisionsSurviveConfigRefresh(durableHasHookState: Bool) throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durableConfig = src.appendingPathComponent("config.toml")
        let managedConfig = dst.appendingPathComponent("config.toml")
        let priorState = durableHasHookState ? """

        [hooks.state."graftty@graftty:hooks/hooks.json:stop:0:0"]
        trusted_hash = "sha256:old-definition"
        trusted_content_hash = "sha256:old-content"
        enabled = true
        """ : ""
        try writeFile(durableConfig, "model = \"old-model\"\n" + priorState)
        let mirror = CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst)
        try mirror.rebuild()

        let acceptedState = """
        [hooks.state."graftty@graftty:hooks/hooks.json:stop:0:0"]
        trusted_hash = "sha256:accepted-definition"
        trusted_content_hash = "sha256:accepted-content"
        enabled = false

        [hooks.state.'other-plugin@example:hooks/hooks.json:session_start:0:0'] # local approval
        trusted_hash = "sha256:other-definition"
        """
        try writeFile(managedConfig, """
        model = "runtime-only-model"
        [features]
        hooks = true
        \(acceptedState)
        """)

        let updatedDurable = """
        model = "new-model"
        [features]
        hooks = false
        [mcp_servers.new_server]
        url = "https://example.com/mcp"
        \(priorState)
        [hooks.state."durable-only"]
        enabled = false
        """
        try writeFile(durableConfig, updatedDurable)

        for _ in 0..<2 {
            try mirror.rebuild()
            let rebuilt = try String(contentsOf: managedConfig, encoding: .utf8)
            #expect(rebuilt.contains(acceptedState))
            #expect(rebuilt.contains("model = \"new-model\""))
            #expect(rebuilt.contains("hooks = false"))
            #expect(rebuilt.contains("[mcp_servers.new_server]"))
            #expect(rebuilt.contains("[hooks.state.\"durable-only\"]"))
            #expect(!rebuilt.contains("old-definition"))
            #expect(!rebuilt.contains("runtime-only-model"))
            #expect(try String(contentsOf: durableConfig, encoding: .utf8) == updatedDurable)
        }
    }

    @Test("Managed hook decisions replace durable dotted state fields without duplicate tables.", arguments: ["hooks.state.\"example\".enabled = true\n", "[hooks]\nstate.\"example\".enabled = true\n", "[hooks.state]\n\"example\".enabled = true\n"])
    func managedHookDecisionsReplaceDottedFields(durableText: String) throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durableConfig = src.appendingPathComponent("config.toml")
        let managedConfig = dst.appendingPathComponent("config.toml")
        try writeFile(durableConfig, durableText)
        let mirror = CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst)
        try mirror.rebuild()
        try writeFile(managedConfig, "[hooks.state.\"example\"]\nenabled = false\n")

        for _ in 0..<2 {
            try mirror.rebuild()
            let rebuilt = try String(contentsOf: managedConfig, encoding: .utf8)
            #expect(!rebuilt.contains("enabled = true"))
            #expect(rebuilt.contains("[hooks.state.\"example\"]\nenabled = false"))
            #expect(try String(contentsOf: durableConfig, encoding: .utf8) == durableText)
        }
    }

    @Test("Config refresh ignores hook-state examples inside multiline strings.")
    func hookStateExamplesAreNotApprovals() throws {
        let (src, dst) = try makeMirrorSandbox()
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let durableConfig = src.appendingPathComponent("config.toml")
        let durableText = "model = \"new-model\"\n"
        try writeFile(durableConfig, durableText)
        let mirror = CodexHomeMirror(sourceDirectory: src, mirrorDirectory: dst)
        try mirror.rebuild()
        try writeFile(dst.appendingPathComponent("config.toml"), """
        instructions = '''
        [hooks.state."example"]
        trusted_hash = "sha256:never-approved"
        '''
        [hooks.Stop]
        command = "runtime-only-hook"
        """)

        try mirror.rebuild()

        #expect(try String(contentsOf: dst.appendingPathComponent("config.toml"), encoding: .utf8) == durableText)
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
