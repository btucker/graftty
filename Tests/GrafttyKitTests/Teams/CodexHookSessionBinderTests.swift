import Foundation
import Testing
@testable import GrafttyKit

@Suite("Codex hook thread binding")
struct CodexHookSessionBinderTests {
    private struct Fixture {
        let root: URL
        let presenceStorage: TeamPresenceStorage
        let sessionStorage: CodexAppServerSessionStorage
        let agentID: String
        let registeredAt: Date

        @discardableResult
        func bind(threadID: String, allowRebind: Bool) throws -> CodexHookSessionBinding? {
            try CodexHookSessionBinder.bind(
                threadID: threadID,
                teamID: "/repo",
                worktree: "/repo/feature",
                paneSessionName: "graftty-aabbccdd",
                agentID: agentID,
                allowRebind: allowRebind,
                presenceStorage: presenceStorage,
                sessionStorage: sessionStorage
            )
        }

        func readPresence() throws -> TeamPresenceRecord? {
            try presenceStorage.read(
                teamID: "/repo",
                worktree: "/repo/feature",
                runtime: .codex,
                paneSessionName: "graftty-aabbccdd",
                agentID: agentID
            )
        }

        func readSession() throws -> CodexAppServerSessionRecord? {
            try sessionStorage.read(
                teamID: "/repo",
                worktree: "/repo/feature",
                paneSessionName: "graftty-aabbccdd"
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-hook-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        return Fixture(
            root: root,
            presenceStorage: presenceStorage,
            sessionStorage: sessionStorage,
            agentID: agentID,
            registeredAt: registeredAt
        )
    }

    @Test("""
    @spec AGENT-6.8: When a wrapped Codex SessionStart hook reports its native `session_id`, the application shall bind that exact thread ID to the wrapper's canonical agent presence and app-server socket while preserving process identity and pane ownership.
    """)
    func bindsHookThreadToPresenceAndTransport() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let binding = try #require(try fixture.bind(threadID: "thread-exact", allowRebind: true))

        #expect(binding.threadID == "thread-exact")
        let presence = try #require(try fixture.readPresence())
        #expect(presence.pid == 101)
        #expect(presence.registeredAt == fixture.registeredAt)
        #expect(presence.runtimeSessionID == "thread-exact")
        #expect(presence.transport == .codex(
            binaryPath: "/bin/codex",
            socketPath: "/tmp/codex.sock",
            threadID: "thread-exact",
            activeTurnID: nil
        ))
        let session = try #require(try fixture.readSession())
        #expect(session.agentID == fixture.agentID)
        #expect(session.threadID == "thread-exact")
    }

    @Test("""
    @spec AGENT-6.23: If a Codex hook reports a thread ID that differs from a stored non-empty thread binding, then the application shall rebind the presence and app-server records only for a session-start invocation; a straggling post-tool-use invocation shall return the stored binding unchanged.
    """)
    func stragglingPostToolUseCannotClobberNewerBinding() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        // Re-host/resume rebinds the pane to thread-two via session-start.
        try fixture.bind(threadID: "thread-two", allowRebind: true)

        // A straggling post-tool-use hook still carrying the dead thread-one
        // must not steer native delivery back into it.
        let stale = try #require(try fixture.bind(threadID: "thread-one", allowRebind: false))
        #expect(stale.threadID == "thread-two")
        let session = try #require(try fixture.readSession())
        #expect(session.threadID == "thread-two")
        let presence = try #require(try fixture.readPresence())
        #expect(presence.runtimeSessionID == "thread-two")
        #expect(presence.transport == .codex(
            binaryPath: "/bin/codex",
            socketPath: "/tmp/codex.sock",
            threadID: "thread-two",
            activeTurnID: nil
        ))

        // A genuine resume announcing thread-one via session-start may rebind.
        try fixture.bind(threadID: "thread-one", allowRebind: true)
        #expect(try fixture.readSession()?.threadID == "thread-one")
        #expect(try fixture.readPresence()?.runtimeSessionID == "thread-one")
    }

    @Test("A post-tool-use hook may fill an empty binding and confirm a matching one.")
    func postToolUseFillsAndConfirmsBinding() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let filled = try #require(try fixture.bind(threadID: "thread-one", allowRebind: false))
        #expect(filled.threadID == "thread-one")
        #expect(try fixture.readSession()?.threadID == "thread-one")

        let confirmed = try #require(try fixture.bind(threadID: "thread-one", allowRebind: false))
        #expect(confirmed.threadID == "thread-one")
        #expect(try fixture.readSession()?.threadID == "thread-one")
        #expect(try fixture.readPresence()?.runtimeSessionID == "thread-one")
    }
}
