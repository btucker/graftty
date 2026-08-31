import Foundation
import Dispatch
import Testing
@testable import GrafttyKit

@Suite("TeamPresenceStorage — pane-specific records")
struct TeamPresenceStorageTests {
    func makeStorage() throws -> TeamPresenceStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TeamPresenceStorage(rootDirectory: dir)
    }

    @Test("Record round-trips paneSessionName when set.")
    func roundTripsPaneSessionName() throws {
        let storage = try makeStorage()
        let record = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneSessionName: "graftty-abc12345",
            pid: 4242,
            processStartTimeMicroseconds: nil,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try storage.write(record)
        let loaded = try #require(storage.listAll().first)
        #expect(loaded.paneSessionName == "graftty-abc12345")
    }

    @Test("Record decodes paneSessionName as nil when field missing (back-compat).")
    func decodesNilWhenFieldMissing() throws {
        let storage = try makeStorage()
        let teamDir = storage.rootDirectory
            .appendingPathComponent(TeamInbox.fileComponent("/repo"), isDirectory: true)
            .appendingPathComponent("presence", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        let oldJSON = """
        {
          "teamID": "/repo",
          "worktree": "/repo/.worktrees/alice",
          "runtime": "codex",
          "pid": 4242,
          "registeredAt": "2023-11-14T22:13:20Z"
        }
        """
        let leaf = TeamInbox.fileComponent("/repo/.worktrees/alice.codex") + ".json"
        try oldJSON.data(using: .utf8)!.write(to: teamDir.appendingPathComponent(leaf))
        let loaded = try #require(storage.listAll().first)
        #expect(loaded.paneSessionName == nil)
        #expect(loaded.processStartTimeMicroseconds == nil)
    }

    @Test("Record round-trips processStartTimeMicroseconds exactly.")
    func roundTripsProcessStartTimeMicrosecondsExactly() throws {
        let storage = try makeStorage()
        let record = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .codex,
            paneSessionName: nil,
            pid: 4242,
            processStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try storage.write(record)
        let loaded = try #require(storage.listAll().first)
        #expect(loaded.processStartTimeMicroseconds == 1_700_000_123_456_789)
    }

    @Test("Record persistence preserves subsecond registration ordering.")
    func roundTripsRegisteredAtFractionalSeconds() throws {
        let storage = try makeStorage()
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let record = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .claude,
            paneSessionName: "graftty-fraction",
            pid: 4242,
            registeredAt: registeredAt
        )

        try storage.write(record)
        let loaded = try #require(storage.listAll().first)

        #expect(abs(loaded.registeredAt.timeIntervalSince(registeredAt)) < 0.001)
    }

    @Test("@spec TEAM-IDLE-2.13: Two records with the same (worktree, runtime) but different paneSessionName coexist.")
    func sameWorktreeRuntimeDifferentPanesCoexist() throws {
        let storage = try makeStorage()
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
        let all = try storage.listAll().sorted { $0.pid < $1.pid }
        #expect(all.count == 2)
        #expect(all.map(\.paneSessionName) == ["graftty-aaaaaaaa", "graftty-bbbbbbbb"])
    }

    @Test("@spec TEAM-IDLE-2.13: Delete by paneSessionName removes only the matching record.")
    func deleteByPaneSessionNameIsTargeted() throws {
        let storage = try makeStorage()
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
        try storage.delete(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa"
        )
        let all = try storage.listAll()
        #expect(all.count == 1)
        #expect(all.first?.paneSessionName == "graftty-bbbbbbbb")
    }

    @Test("@spec TEAM-IDLE-2.15: Deleting by paneSessionName mirrors a pane-close cleanup sweep.")
    func paneCloseSweepRemovesMatchingRecord() throws {
        let storage = try makeStorage()
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
        // Mimic the GrafttyApp pane-close cleanup loop.
        let closingSessionName = "graftty-aaaaaaaa"
        for record in try storage.listAll() where record.paneSessionName == closingSessionName {
            try storage.delete(
                teamID: record.teamID, worktree: record.worktree,
                runtime: record.runtime, paneSessionName: record.paneSessionName
            )
        }
        let surviving = try storage.listAll()
        #expect(surviving.count == 1)
        #expect(surviving.first?.paneSessionName == "graftty-bbbbbbbb")
    }

    @Test("Presence index returns all records for a pane session without reading storage.")
    func presenceIndexGroupsAllRecordsForPaneSession() {
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let codex = TeamPresenceRecord(
            teamID: "team",
            worktree: "wt",
            runtime: .codex,
            paneSessionName: "graftty-aaaaaaaa",
            pid: 1,
            processStartTimeMicroseconds: nil,
            registeredAt: registeredAt
        )
        let claude = TeamPresenceRecord(
            teamID: "team",
            worktree: "wt",
            runtime: .claude,
            paneSessionName: "graftty-aaaaaaaa",
            pid: 2,
            processStartTimeMicroseconds: nil,
            registeredAt: registeredAt
        )
        let other = TeamPresenceRecord(
            teamID: "team",
            worktree: "wt",
            runtime: .codex,
            paneSessionName: "graftty-bbbbbbbb",
            pid: 3,
            processStartTimeMicroseconds: nil,
            registeredAt: registeredAt
        )
        let index = TeamPresenceIndex(records: [codex, claude, other])

        #expect(index.records(forPaneSessionName: "graftty-aaaaaaaa") == [codex, claude])

        index.remove(
            teamID: codex.teamID,
            worktree: codex.worktree,
            runtime: codex.runtime,
            paneSessionName: codex.paneSessionName
        )

        #expect(index.records(forPaneSessionName: "graftty-aaaaaaaa") == [claude])
        #expect(index.allRecords() == [claude, other])
    }

    @Test("Delete with paneSessionName == nil removes only the worktree-only record.")
    func deleteNilPaneOnlyTouchesWorktreeRecord() throws {
        let storage = try makeStorage()
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: nil, pid: 1,
            processStartTimeMicroseconds: nil, registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-bbbbbbbb", pid: 2,
            processStartTimeMicroseconds: nil, registeredAt: registeredAt
        ))
        try storage.delete(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: nil
        )
        let all = try storage.listAll()
        #expect(all.count == 1)
        #expect(all.first?.paneSessionName == "graftty-bbbbbbbb")
    }

    @Test("Scoped presence listing reads only one team's worktree and runtime.")
    func scopedPresenceListing() throws {
        let storage = try makeStorage()
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .claude,
            paneSessionName: "graftty-aaaaaaaa",
            pid: 1,
            registeredAt: registeredAt
        )
        try storage.write(expected)
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex,
            paneSessionName: "graftty-bbbbbbbb", pid: 2, registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/repo", worktree: "/repo/.worktrees/bob", runtime: .claude,
            paneSessionName: "graftty-cccccccc", pid: 3, registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/other", worktree: "/repo/.worktrees/alice", runtime: .claude,
            paneSessionName: "graftty-dddddddd", pid: 4, registeredAt: registeredAt
        ))

        #expect(try storage.list(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: .claude
        ) == [expected])
    }

    @Test("Claude session binding mutations are serialized within a process.")
    func claudeBindingMutationsAreSerialized() throws {
        let storage = try makeStorage()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = try? storage.withClaudeBindingLock(teamID: "/repo") {
                firstEntered.signal()
                releaseFirst.wait()
            }
            completed.signal()
        }
        #expect(firstEntered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            _ = try? storage.withClaudeBindingLock(teamID: "/repo") {
                secondEntered.signal()
            }
            completed.signal()
        }

        #expect(secondEntered.wait(timeout: .now() + 0.05) == .timedOut)
        releaseFirst.signal()
        #expect(secondEntered.wait(timeout: .now() + 1) == .success)
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(completed.wait(timeout: .now() + 1) == .success)
    }
}
