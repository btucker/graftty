#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import GrafttyKit

@Suite("Claude native peer-session registry")
struct ClaudePeerSessionRegistryTests {
    @Test("@spec AGENT-6.39: When a native agent exposes its messaging socket through a symbolic link, the application shall treat the link as reachable only while it resolves to a socket.")
    func socketSymlinkReachability() throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-socket-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("server.sock")
        let linkPath = directory.appendingPathComponent("codex.sock")

        let listener = GrafttyPOSIX.socket(AF_UNIX, GrafttyPOSIX.streamSocket, 0)
        #expect(listener >= 0)
        guard listener >= 0 else { return }
        defer { GrafttyPOSIX.close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: Array(socketPath.path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                GrafttyPOSIX.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        guard bound == 0 else { return }
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: socketPath)

        #expect(ClaudePeerSessionRegistry.isSocket(atPath: socketPath.path))
        #expect(ClaudePeerSessionRegistry.isSocket(atPath: linkPath.path))
        try FileManager.default.removeItem(at: socketPath)
        #expect(!ClaudePeerSessionRegistry.isSocket(atPath: linkPath.path))
    }

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

    @Test("""
    @spec AGENT-6.63: If a Claude registry row holds a complete JSON object followed by stale bytes from an earlier, longer rewrite, then the application shall read the leading object as that session's row, while a row whose object never completes shall remain unreadable.
    """)
    func readsRowWithStaleTrailingBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-claude-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Claude 2.1.314 rewrote a row in place one byte shorter and left the
        // previous object's closing brace behind.
        try write(
            #"{"pid":101,"sessionId":"trailing","cwd":"/repo/feature","name":"re{vie}wer","kind":"interactive","peerProtocol":1,"messagingSocketPath":"/tmp/cc-socks/101.sock"}}"#,
            to: root.appendingPathComponent("101.json")
        )
        try write(
            #"{"pid":102,"sessionId":"longer-tail","cwd":"/repo/feature","peerProtocol":1,"messagingSocketPath":"/tmp/cc-socks/102.sock"},"kind":"interactive"}"#,
            to: root.appendingPathComponent("102.json")
        )
        try write(
            #"{"pid":103,"sessionId":"truncated","cwd":"/repo/feature","peerProtocol":1,"messagingSocketPath":"/tmp/cc-socks/103.sock""#,
            to: root.appendingPathComponent("103.json")
        )

        let registry = ClaudePeerSessionRegistry(
            directory: root,
            processStartTimeMicroseconds: { _ in 10_001 },
            socketIsReachable: { _ in true }
        )
        func record(_ sessionID: String) -> TeamPresenceRecord? {
            registry.presenceRecord(
                sessionID: sessionID, expectedWorktree: "/repo/feature", teamID: "/repo", paneSessionName: nil
            )
        }
        let trailing = try #require(record("trailing"))
        #expect(trailing.pid == 101)
        #expect(trailing.nativeDisplayName == "re{vie}wer")
        #expect(trailing.transport == .claude(socketPath: "/tmp/cc-socks/101.sock", protocolVersion: 1))
        #expect(record("longer-tail")?.pid == 102)
        #expect(record("truncated") == nil)
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
