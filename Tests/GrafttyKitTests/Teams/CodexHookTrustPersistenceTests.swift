import Foundation
import Testing
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("Codex hook trust persistence")
struct CodexHookTrustPersistenceTests {
    @Test("@spec TEAM-10.24: When Codex saves hook trust or enablement through the managed home, the application shall retain those native choices in the durable config across subsequent launches without bypassing hook review.", arguments: [true, false])
    func nativeHookChoicesSurviveRebuild(trusted: Bool) throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = root.appendingPathComponent("durable")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: durable, withIntermediateDirectories: true)
        try "model = \"test-model\"\n".write(
            to: durable.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        let mirror = CodexHomeMirror(sourceDirectory: durable, mirrorDirectory: managed)
        try mirror.rebuild()
        let config = managed.appendingPathComponent("config.toml")
        let choice = """
        model = "test-model"
        [hooks.state."graftty@graftty:hooks/hooks.json:stop:0:0"]
        enabled = \(trusted)
        trusted_hash = "\(trusted ? "reviewed-definition" : "")"
        """

        // Codex's native config writer resolves a config symlink before its
        // atomic replacement. Exercise the same write through the managed path.
        try choice.write(to: config.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: durable.appendingPathComponent("config.toml"), encoding: .utf8) == choice)
        for _ in 0..<2 {
            try mirror.rebuild()
            #expect(try String(contentsOf: config, encoding: .utf8) == choice)
        }
    }

    @Test("@spec TEAM-10.25: When Graftty replaces a divergent managed Codex config snapshot with the durable config link, the application shall preserve the snapshot in a recovery file and keep durable hook choices authoritative.")
    func divergentSnapshotDoesNotRestoreRevokedTrust() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = root.appendingPathComponent("durable")
        let managed = root.appendingPathComponent("managed")
        let mirror = CodexHomeMirror(sourceDirectory: durable, mirrorDirectory: managed)
        try mirror.rebuild()
        let config = managed.appendingPathComponent("config.toml")
        let durableConfig = durable.appendingPathComponent("config.toml")
        let revoked = """
        [hooks.state."fixture-hook"]
        enabled = false
        trusted_hash = ""
        """
        let snapshot = """
        [hooks.state."fixture-hook"]
        enabled = true
        trusted_hash = "previous-approval"
        """
        try revoked.write(to: durableConfig, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: config)
        try snapshot.write(to: config, atomically: true, encoding: .utf8)

        try mirror.rebuild()

        #expect(try String(contentsOf: config, encoding: .utf8) == revoked)
        #expect(try String(contentsOf: durableConfig, encoding: .utf8) == revoked)
        #expect(try String(contentsOf: durable.appendingPathComponent("config.toml.graftty-snapshot"), encoding: .utf8) == snapshot)
        try mirror.rebuild()
        #expect(!FileManager.default.fileExists(atPath: durable.appendingPathComponent("config.toml.graftty-snapshot-1").path))
    }
}
