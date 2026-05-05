import Foundation
import Testing
@testable import GrafttyKit

@Suite("Agent Hook Installer")
struct AgentHookInstallerTests {
    @Test func installWritesWrappersIdempotently() throws {
        let root = try Self.temporaryDirectory()
        let installer = AgentHookInstaller(rootDirectory: root, grafttyCLIPath: "/usr/local/bin/graftty")

        let first = try installer.install()
        let second = try installer.install()

        #expect(first.writtenFiles.count == 2)
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
            grafttyCLIPath: "/app/graftty"
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
            grafttyCLIPath: "/app/graftty"
        )

        #expect(script.contains(#"if [ "$dir" = '/tmp/has $dollar/it'"'"'s/bin' ]; then"#))
        // Inline JSON is passed via --settings, single-quoted (with escaped single quotes if any).
        #expect(script.contains(#"--settings '"#))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
