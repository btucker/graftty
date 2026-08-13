import Foundation
import Testing
@testable import GrafttyKit

@Suite("Claude native peer-session registry")
struct ClaudePeerSessionRegistryTests {
    @Test("""
    @spec AGENT-6.5: When a Claude SessionStart hook identifies a live protocol-v1 top-level registry record for its session in Claude's configured state directory, the application shall register that native session with its canonical agent ID, process identity, messaging socket, provider display label, worktree, and pane; malformed, stale, unsupported, mismatched, and subagent records shall not become routable agents.
    """)
    func discoversOnlyCompatibleTopLevelSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-claude-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try write(
            #"{"pid":101,"sessionId":"wanted","cwd":"/repo/feature","name":"reviewer","kind":"interactive","peerProtocol":1,"messagingSocketPath":"/tmp/cc-socks/101.sock"}"#,
            to: root.appendingPathComponent("101.json")
        )
        try write(
            #"{"pid":102,"sessionId":"child","cwd":"/repo/feature","kind":"subagent","peerProtocol":1,"messagingSocketPath":"/tmp/cc-socks/102.sock"}"#,
            to: root.appendingPathComponent("102.json")
        )
        try write(
            #"{"pid":103,"sessionId":"future","cwd":"/repo/feature","kind":"interactive","peerProtocol":2,"messagingSocketPath":"/tmp/cc-socks/103.sock"}"#,
            to: root.appendingPathComponent("103.json")
        )

        let registry = ClaudePeerSessionRegistry(
            directory: root,
            processStartTimeMicroseconds: { $0 == 101 ? 10_001 : nil },
            socketIsReachable: { $0 == "/tmp/cc-socks/101.sock" }
        )
        let record = try #require(registry.presenceRecord(
            sessionID: "wanted",
            expectedWorktree: "/repo/feature",
            teamID: "/repo",
            paneSessionName: "graftty-aabbccdd",
            registeredAt: Date(timeIntervalSince1970: 10)
        ))

        #expect(record.pid == 101)
        #expect(record.processStartTimeMicroseconds == 10_001)
        #expect(record.nativeDisplayName == "reviewer")
        #expect(record.agentID == TeamAgentIdentity(runtime: .claude, nativeSessionID: "wanted").rawValue)
        #expect(record.transport == .claude(socketPath: "/tmp/cc-socks/101.sock", protocolVersion: 1))
        #expect(registry.presenceRecord(
            sessionID: "child",
            expectedWorktree: "/repo/feature",
            teamID: "/repo",
            paneSessionName: nil
        ) == nil)
        #expect(registry.presenceRecord(
            sessionID: "future",
            expectedWorktree: "/repo/feature",
            teamID: "/repo",
            paneSessionName: nil
        ) == nil)
        #expect(registry.presenceRecord(
            sessionID: "wanted",
            expectedWorktree: "/repo/other",
            teamID: "/repo",
            paneSessionName: nil
        ) == nil)
    }

    @Test("The default registry follows Claude's configured state directory.")
    func defaultDirectoryHonorsClaudeConfigDirectory() {
        let home = URL(fileURLWithPath: "/Users/example")
        let configured = URL(fileURLWithPath: "/tmp/claude-profile")

        #expect(ClaudePeerSessionRegistry.defaultDirectory(
            homeDirectory: home,
            environment: ["CLAUDE_CONFIG_DIR": configured.path]
        ) == configured.appendingPathComponent("sessions", isDirectory: true))
        #expect(ClaudePeerSessionRegistry.defaultDirectory(
            homeDirectory: home,
            environment: ["CLAUDE_CONFIG_DIR": "   "]
        ) == home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true))
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url)
    }
}
