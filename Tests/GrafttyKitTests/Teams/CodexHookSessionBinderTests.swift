import Foundation
import Testing
@testable import GrafttyKit

@Suite("Codex hook thread binding")
struct CodexHookSessionBinderTests {
    @Test("""
    @spec AGENT-6.8: When a wrapped Codex SessionStart hook reports its native `session_id`, the application shall bind that exact thread ID to the wrapper's canonical agent presence and app-server socket while preserving process identity and pane ownership.
    """)
    func bindsHookThreadToPresenceAndTransport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-hook-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let presenceStorage = TeamPresenceStorage(rootDirectory: root)
        let sessionStorage = CodexAppServerSessionStorage(rootDirectory: root)
        let agentID = TeamAgentIdentity(runtime: .codex, nativeSessionID: "bootstrap").rawValue
        let registeredAt = Date(timeIntervalSince1970: 10)
        try presenceStorage.write(.init(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .codex,
            paneSessionName: "graftty-aabbccdd",
            pid: 101,
            processStartTimeMicroseconds: 1_001,
            registeredAt: registeredAt,
            agentID: agentID
        ))
        try sessionStorage.write(.init(
            teamID: "/repo",
            worktree: "/repo/feature",
            paneSessionName: "graftty-aabbccdd",
            socketPath: "/tmp/codex.sock",
            realBinaryPath: "/bin/codex",
            appServerPID: 201,
            appServerProcessStartTimeMicroseconds: 2_001,
            registeredAt: registeredAt
        ))

        let binding = try #require(try CodexHookSessionBinder.bind(
            threadID: "thread-exact",
            teamID: "/repo",
            worktree: "/repo/feature",
            paneSessionName: "graftty-aabbccdd",
            agentID: agentID,
            presenceStorage: presenceStorage,
            sessionStorage: sessionStorage
        ))

        #expect(binding.threadID == "thread-exact")
        let presence = try #require(try presenceStorage.read(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .codex,
            paneSessionName: "graftty-aabbccdd",
            agentID: agentID
        ))
        #expect(presence.pid == 101)
        #expect(presence.registeredAt == registeredAt)
        #expect(presence.runtimeSessionID == "thread-exact")
        #expect(presence.transport == .codex(
            binaryPath: "/bin/codex",
            socketPath: "/tmp/codex.sock",
            threadID: "thread-exact",
            activeTurnID: nil
        ))
        let session = try #require(try sessionStorage.read(
            teamID: "/repo",
            worktree: "/repo/feature",
            paneSessionName: "graftty-aabbccdd"
        ))
        #expect(session.agentID == agentID)
        #expect(session.threadID == "thread-exact")
    }
}
