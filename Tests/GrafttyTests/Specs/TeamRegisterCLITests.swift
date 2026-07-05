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

    @Test("App-server PID must be positive.")
    func appServerPIDMustBePositive() {
        #expect(throws: (any Error).self) {
            try TeamCodexAppServerPIDResolver.resolve(
                appServerPid: 0,
                startTimeMicroseconds: { _ in 123 }
            )
        }
    }

    @Test("App-server PID must identify a readable running process.")
    func appServerPIDMustHaveReadableStartTime() {
        #expect(throws: (any Error).self) {
            try TeamCodexAppServerPIDResolver.resolve(
                appServerPid: 42,
                startTimeMicroseconds: { (_: Int32) -> Int64? in nil }
            )
        }
    }

    @Test("App-server register helper writes metadata for canonical worktree and pane session.")
    func codexAppServerRegisterWritesCanonicalWorktreeMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)

        let record = try TeamCodexAppServerCore.register(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/codex.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: registeredAt
        )

        #expect(record.teamID == "/repo")
        #expect(record.worktree == "/repo/.worktrees/alice")
        #expect(record.paneSessionName == "graftty-aaaaaaaa")
        #expect(record.socketPath == "/tmp/codex.sock")
        #expect(record.realBinaryPath == "/opt/bin/codex")
        #expect(record.appServerPID == 42)
        #expect(record.appServerProcessStartTimeMicroseconds == 1_700_000_123_456_789)

        let loaded = try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        )
        #expect(loaded == record)
    }

    @Test("App-server unregister deletes only the exact team/worktree/pane record.")
    func codexAppServerUnregisterDeletesExactRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        try storage.write(.init(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/a.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-bbbbbbbb",
            socketPath: "/tmp/b.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 43,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_790,
            registeredAt: registeredAt
        ))

        let prior = try TeamCodexAppServerCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            expectedSocketPath: "/tmp/a.sock",
            expectedAppServerPID: 42
        )

        #expect(prior?.paneSessionName == "graftty-aaaaaaaa")
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        ) == nil)
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-bbbbbbbb"
        )?.socketPath == "/tmp/b.sock")
    }

    @Test("App-server unregister leaves current record when stale cleanup socket mismatches.")
    func codexAppServerUnregisterPreservesMismatchedSocketRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let current = CodexAppServerSessionRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/current.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try storage.write(current)

        let prior = try TeamCodexAppServerCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            expectedSocketPath: "/tmp/stale.sock",
            expectedAppServerPID: 42
        )

        #expect(prior == nil)
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        ) == current)
    }

    @Test("App-server unregister leaves current record when stale cleanup PID mismatches.")
    func codexAppServerUnregisterPreservesMismatchedPIDRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let current = CodexAppServerSessionRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/current.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 43,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_790,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try storage.write(current)

        let prior = try TeamCodexAppServerCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            expectedSocketPath: "/tmp/current.sock",
            expectedAppServerPID: 42
        )

        #expect(prior == nil)
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        ) == current)
    }

    @Test("Presence resolution returns the canonical worktree path for delivery ownership.")
    func presenceResolutionReturnsCanonicalWorktreePath() throws {
        let state = AppState(repos: [
            RepoEntry(path: "/repo", displayName: "repo", worktrees: [
                WorktreeEntry(path: "/repo", branch: "main"),
                WorktreeEntry(path: "/repo/.worktrees/alice", branch: "alice"),
            ]),
        ])

        let resolved = try #require(TeamPresenceCLI.resolveTeamAndWorktree(
            state: state,
            worktreePath: "/repo/.worktrees/alice"
        ))

        #expect(TeamLookup.id(of: resolved.team) == "/repo")
        #expect(resolved.worktreePath == "/repo/.worktrees/alice")
        #expect(resolved.memberName == "alice")
    }

    @Test("Presence migration removes legacy member-name keyed records.")
    func presenceMigrationRemovesLegacyMemberNameRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = TeamPresenceStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        try storage.write(.init(
            teamID: "/repo", worktree: "alice", runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa", pid: 1,
            processStartTimeMicroseconds: nil, registeredAt: registeredAt
        ))
        let resolved = TeamPresenceCLI.Resolved(
            team: TeamView(repoPath: "/repo", repoDisplayName: "repo", members: []),
            worktreePath: "/repo/.worktrees/alice",
            memberName: "alice"
        )

        let prior = try TeamPresenceCLI.deleteLegacyMemberNamePresence(
            storage: storage,
            teamID: "/repo",
            resolved: resolved,
            runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa"
        )

        #expect(prior?.worktree == "alice")
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "alice",
            runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa"
        ) == nil)
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
            paneSessionName: "graftty-aaaaaaaa", pid: 1,
            processStartTimeMicroseconds: nil, registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-bbbbbbbb", pid: 2,
            processStartTimeMicroseconds: nil, registeredAt: registeredAt
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
