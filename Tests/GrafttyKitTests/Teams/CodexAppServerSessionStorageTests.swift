import Foundation
import Testing
@testable import GrafttyKit

@Suite("CodexAppServerSessionStorage")
struct CodexAppServerSessionStorageTests {
    func makeStorage() throws -> CodexAppServerSessionStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return CodexAppServerSessionStorage(rootDirectory: dir)
    }

    func record(
        teamID: String = "/repo",
        worktree: String = "/repo/.worktrees/alice",
        paneSessionName: String = "graftty-aaaaaaaa",
        socketPath: String = "/tmp/graftty.sock",
        realBinaryPath: String = "/usr/local/bin/codex",
        appServerPID: Int32 = 4242,
        appServerProcessStartTimeMicroseconds: Int64? = 1_700_000_123_456_789,
        registeredAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> CodexAppServerSessionRecord {
        CodexAppServerSessionRecord(
            teamID: teamID,
            worktree: worktree,
            paneSessionName: paneSessionName,
            socketPath: socketPath,
            realBinaryPath: realBinaryPath,
            appServerPID: appServerPID,
            appServerProcessStartTimeMicroseconds: appServerProcessStartTimeMicroseconds,
            registeredAt: registeredAt
        )
    }

    @Test("Record round-trips by team, worktree, and pane session.")
    func roundTripsByTeamWorktreeAndPane() throws {
        let storage = try makeStorage()
        let original = record()

        try storage.write(original)

        let loaded = try #require(try storage.read(
            teamID: original.teamID,
            worktree: original.worktree,
            paneSessionName: original.paneSessionName
        ))
        #expect(loaded == original)
        let expectedURL = storage.rootDirectory
            .appendingPathComponent(TeamInbox.fileComponent(original.teamID), isDirectory: true)
            .appendingPathComponent("codex-app-servers", isDirectory: true)
            .appendingPathComponent(TeamInbox.fileComponent("\(original.worktree).\(original.paneSessionName)") + ".json")
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    @Test("listAll returns records across multiple team directories.")
    func listAllReturnsRecordsAcrossTeams() throws {
        let storage = try makeStorage()
        let first = record(teamID: "team-a", paneSessionName: "pane-a", appServerPID: 1)
        let second = record(teamID: "team-b", paneSessionName: "pane-b", appServerPID: 2)

        try storage.write(first)
        try storage.write(second)

        let all = try storage.listAll().sorted { $0.appServerPID < $1.appServerPID }
        #expect(all == [first, second])
    }

    @Test("delete is idempotent and removes only the addressed record.")
    func deleteIsIdempotentAndTargeted() throws {
        let storage = try makeStorage()
        let first = record(paneSessionName: "pane-a", appServerPID: 1)
        let second = record(paneSessionName: "pane-b", appServerPID: 2)
        let third = record(teamID: "other-team", paneSessionName: "pane-a", appServerPID: 3)

        try storage.write(first)
        try storage.write(second)
        try storage.write(third)

        try storage.delete(teamID: first.teamID, worktree: first.worktree, paneSessionName: first.paneSessionName)
        try storage.delete(teamID: first.teamID, worktree: first.worktree, paneSessionName: first.paneSessionName)

        #expect(try storage.read(
            teamID: first.teamID,
            worktree: first.worktree,
            paneSessionName: first.paneSessionName
        ) == nil)
        let remaining = try storage.listAll().sorted { $0.appServerPID < $1.appServerPID }
        #expect(remaining == [second, third])
    }

    @Test("cleanup removes records for dead app-server PIDs.")
    func cleanupRemovesDeadPID() throws {
        let storage = try makeStorage()
        let stale = record(appServerPID: 100)
        try storage.write(stale)

        try storage.cleanupStale(isAlive: { _ in false }, processStartTimeMicroseconds: { _ in nil })

        #expect(try storage.listAll().isEmpty)
    }

    @Test("cleanup removes records when process identity differs.")
    func cleanupRemovesProcessIdentityMismatch() throws {
        let storage = try makeStorage()
        let stale = record(appServerPID: 100, appServerProcessStartTimeMicroseconds: 10)
        try storage.write(stale)

        try storage.cleanupStale(isAlive: { _ in true }, processStartTimeMicroseconds: { _ in 20 })

        #expect(try storage.listAll().isEmpty)
    }

    @Test("cleanup keeps live records with matching process identity.")
    func cleanupKeepsLiveMatchingIdentity() throws {
        let storage = try makeStorage()
        let live = record(appServerPID: 100, appServerProcessStartTimeMicroseconds: 10)
        try storage.write(live)

        try storage.cleanupStale(isAlive: { _ in true }, processStartTimeMicroseconds: { _ in 10 })

        #expect(try storage.listAll() == [live])
    }

    @Test("cleanup keeps live records with no stored process identity.")
    func cleanupKeepsLiveNilStoredProcessIdentity() throws {
        let storage = try makeStorage()
        let live = record(appServerPID: 100, appServerProcessStartTimeMicroseconds: nil)
        try storage.write(live)

        try storage.cleanupStale(isAlive: { _ in true }, processStartTimeMicroseconds: { _ in nil })

        #expect(try storage.listAll() == [live])
    }
}
