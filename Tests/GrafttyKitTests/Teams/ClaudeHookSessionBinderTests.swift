import Foundation
import Testing
@testable import GrafttyKit

@Suite("Claude hook session binding")
struct ClaudeHookSessionBinderTests {
    private struct Fixture {
        let root: URL
        let storage: TeamPresenceStorage

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-claude-hook-bind-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            storage = TeamPresenceStorage(rootDirectory: root)
        }

        func record(
            sessionID: String,
            registeredAt: TimeInterval,
            pane: String = "graftty-aabbccdd",
            pid: Int32 = 101,
            processStart: Int64 = 1_001,
            socketPath: String = "/tmp/claude-101.sock"
        ) -> TeamPresenceRecord {
            TeamPresenceRecord(
                teamID: "/repo",
                worktree: "/repo/feature",
                runtime: .claude,
                paneSessionName: pane,
                pid: pid,
                processStartTimeMicroseconds: processStart,
                registeredAt: Date(timeIntervalSince1970: registeredAt),
                runtimeSessionID: sessionID,
                agentID: TeamAgentIdentity(
                    runtime: .claude,
                    nativeSessionID: sessionID
                ).rawValue,
                transport: .claude(socketPath: socketPath, protocolVersion: 1)
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("""
    @spec AGENT-6.25: When a Claude SessionStart hook binds a new session identity to the same live process and peer socket as an older identity in one worktree, the application shall replace the superseded presence row; if a later non-SessionStart hook reports the superseded identity, then the application shall preserve the new binding rather than resurrect the old agent.
    """)
    func clearReplacesOldIdentityAndLateStopCannotRestoreIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let old = fixture.record(sessionID: "before-clear", registeredAt: 10)
        let current = fixture.record(sessionID: "after-clear", registeredAt: 20)
        try fixture.storage.write(old)

        let bound = try ClaudeHookSessionBinder.bind(
            current,
            event: .sessionStart,
            storage: fixture.storage
        )

        #expect(bound == current)
        #expect(try fixture.storage.listAll() == [current])

        // Claude can emit the old session's Stop hook after the new
        // SessionStart. Its registry row still points at the shared live
        // socket, and the deleted presence no longer supplies its old date.
        let lateOldStop = fixture.record(sessionID: "before-clear", registeredAt: 30)
        let preserved = try ClaudeHookSessionBinder.bind(
            lateOldStop,
            event: .stop,
            storage: fixture.storage
        )

        #expect(preserved == current)
        #expect(try fixture.storage.listAll() == [current])
    }

    @Test("A new Claude session leaves a separate live peer endpoint intact.")
    func separateEndpointCoexists() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let other = fixture.record(
            sessionID: "other-pane",
            registeredAt: 10,
            pane: "graftty-eeeeffff",
            pid: 202,
            processStart: 2_002,
            socketPath: "/tmp/claude-202.sock"
        )
        let current = fixture.record(sessionID: "current", registeredAt: 20)
        try fixture.storage.write(other)

        _ = try ClaudeHookSessionBinder.bind(
            current,
            event: .sessionStart,
            storage: fixture.storage
        )

        #expect(Set(try fixture.storage.listAll().compactMap(\.agentID)) == [
            other.agentID,
            current.agentID,
        ])
    }

    @Test("A first non-SessionStart hook may discover an unbound live session.")
    func nonSessionStartCanFillEmptyBinding() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let discovered = fixture.record(sessionID: "installed-mid-session", registeredAt: 10)

        let bound = try ClaudeHookSessionBinder.bind(
            discovered,
            event: .stop,
            storage: fixture.storage
        )

        #expect(bound == discovered)
        #expect(try fixture.storage.listAll() == [discovered])
    }
}
