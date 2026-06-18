import Foundation
import Testing
@testable import GrafttyCLI
@testable import GrafttyKit

@Suite("graftty team register — pane resolution")
struct TeamRegisterCLITests {
    @Test("@spec TEAM-IDLE-2.9: When ZMX_SESSION is set, the recorded paneSessionName equals it.")
    func paneSessionNameFromZmxSession() {
        let env = ["ZMX_SESSION": "graftty-abc12345"]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == "graftty-abc12345")
    }

    @Test("@spec TEAM-IDLE-2.10: When ZMX_SESSION is unset, the recorded paneSessionName is nil.")
    func paneSessionNameNilWhenUnset() {
        let env: [String: String] = [:]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }

    @Test("Empty ZMX_SESSION is treated as unset.")
    func paneSessionNameNilWhenEmpty() {
        let env = ["ZMX_SESSION": ""]
        let resolved = TeamRegisterPaneResolver.paneSessionName(env: env)
        #expect(resolved == nil)
    }

    @Test("Explicit --pid must be positive.")
    func explicitPIDMustBePositive() {
        #expect(throws: (any Error).self) {
            try TeamRegisterPIDResolver.resolve(
                explicitPID: 0,
                processIdentifier: 99,
                startTimeMicroseconds: { _ in 123 }
            )
        }
    }

    @Test("Explicit --pid must identify a readable running process.")
    func explicitPIDMustHaveReadableStartTime() {
        #expect(throws: (any Error).self) {
            try TeamRegisterPIDResolver.resolve(
                explicitPID: 42,
                processIdentifier: 99,
                startTimeMicroseconds: { (_: Int32) -> Int64? in nil }
            )
        }
    }

    @Test("Explicit --pid records the validated process identity.")
    func explicitPIDRecordsValidatedIdentity() throws {
        let identity = try TeamRegisterPIDResolver.resolve(
            explicitPID: 42,
            processIdentifier: 99,
            startTimeMicroseconds: { pid in pid == 42 ? 1_700_000_123_456_789 : nil }
        )

        #expect(identity.pid == 42)
        #expect(identity.processStartTimeMicroseconds == 1_700_000_123_456_789)
    }

    @Test("Direct register invocation keeps best-effort start-time behavior.")
    func directInvocationKeepsBestEffortStartTime() throws {
        let identity = try TeamRegisterPIDResolver.resolve(
            explicitPID: Optional<Int32>.none,
            processIdentifier: 99,
            startTimeMicroseconds: { (_: Int32) -> Int64? in nil }
        )

        #expect(identity.pid == 99)
        #expect(identity.processStartTimeMicroseconds == nil)
    }

    @Test("@spec TEAM-IDLE-2.13: Unregister with ZMX_SESSION set targets only that pane's record.")
    func unregisterWithZmxSessionDeletesOnlyMatchingRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = TeamPresenceStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa", pid: 1, registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: registeredAt
        ))

        try TeamUnregisterCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa"
        )

        let surviving = try storage.listAll()
        #expect(surviving.count == 1)
        #expect(surviving.first?.paneSessionName == "graftty-bbbbbbbb")
    }
}
