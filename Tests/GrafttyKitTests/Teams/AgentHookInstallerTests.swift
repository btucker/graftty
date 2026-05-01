import Foundation
import Testing
@testable import GrafttyKit

@Suite("Agent Hook Installer")
struct AgentHookInstallerTests {
    @Test func installWritesWrappersAndSettingsIdempotently() throws {
        let root = try Self.temporaryDirectory()
        let installer = AgentHookInstaller(rootDirectory: root, grafttyCLIPath: "/usr/local/bin/graftty")

        let first = try installer.install()
        let second = try installer.install()

        #expect(first.writtenFiles.count == 3)
        #expect(second.writtenFiles.isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/claude").path))
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/codex").path))
    }

    @Test func installRepairsStaleWrapperMarker() throws {
        let root = try Self.temporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stale = bin.appendingPathComponent("claude")
        try "# GRAFTTY_AGENT_HOOK_WRAPPER version=old\n".write(to: stale, atomically: true, encoding: .utf8)

        let installer = AgentHookInstaller(rootDirectory: root, grafttyCLIPath: "/usr/local/bin/graftty")
        let result = try installer.install()
        let repaired = try String(contentsOf: stale, encoding: .utf8)

        #expect(result.writtenFiles.contains(stale))
        #expect(repaired.contains("version=\(AgentHookInstaller.version)"))
        #expect(repaired.contains("graftty team hook claude"))
    }

    @Test func wrapperSearchSkipsGeneratedBinDirectory() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/app/hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/app/graftty",
            claudeSettingsPath: nil
        )

        #expect(script.contains(#"if [ "$dir" = '/app/hooks/bin' ]; then"#))
        #expect(script.contains("continue"))
        #expect(script.contains(#"exec "$real_binary" "$@""#))
    }

    @Test func wrapperQuotesShellPathsWithoutExpansion() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/tmp/has $dollar/it's/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/app/graftty",
            claudeSettingsPath: "/tmp/has $dollar/it's/settings.json"
        )

        #expect(script.contains(#"if [ "$dir" = '/tmp/has $dollar/it'"'"'s/bin' ]; then"#))
        #expect(script.contains(#"exec "$real_binary" --settings '/tmp/has $dollar/it'"'"'s/settings.json' "$@""#))
    }

    @Test func claudeSettingsContainGrafttyHooks() throws {
        let data = AgentHookInstaller.claudeSettingsData(grafttyCLIPath: "/app/graftty")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        #expect(hooks.keys.contains("SessionStart"))
        #expect(hooks.keys.contains("PostToolUse"))
        #expect(hooks.keys.contains("Stop"))
        #expect(String(data: data, encoding: .utf8)!.contains("/app/graftty team hook claude stop"))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
