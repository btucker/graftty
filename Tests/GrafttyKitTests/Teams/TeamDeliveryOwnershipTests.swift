import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team delivery ownership")
struct TeamDeliveryOwnershipTests {
    @Test("Earliest live record wins for a team, worktree, and runtime.")
    func earliestLiveRecordWins() throws {
        let key = ownerKey()
        let records = [
            record(sessionName: "graftty-later001", pid: 101, start: 10_001, registeredAt: 20),
            record(sessionName: "graftty-owner001", pid: 102, start: 10_002, registeredAt: 10),
        ]
        let resolver = resolver(
            records: records,
            liveSessions: ["graftty-later001", "graftty-owner001"],
            processStartTimes: [101: 10_001, 102: 10_002]
        )

        let owner = try #require(resolver.owner(for: key))

        #expect(owner.paneSessionName == "graftty-owner001")
        #expect(owner.pid == 102)
        #expect(owner.processStartTimeMicroseconds == 10_002)
        #expect(owner.registeredAt == Date(timeIntervalSince1970: 10))
        #expect(owner.key == key)
    }

    @Test("Records without pane session names are ignored.")
    func recordsWithoutPaneSessionNamesAreIgnored() throws {
        let resolver = resolver(
            records: [
                record(sessionName: nil, pid: 101, start: 10_001, registeredAt: 10),
                record(sessionName: "graftty-owner001", pid: 102, start: 10_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-owner001"],
            processStartTimes: [101: 10_001, 102: 10_002]
        )

        let owner = try #require(resolver.owner(for: ownerKey()))

        #expect(owner.paneSessionName == "graftty-owner001")
    }

    @Test("Records whose pane session is not live are ignored.")
    func recordsWhosePaneSessionIsNotLiveAreIgnored() throws {
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-dead0001", pid: 101, start: 10_001, registeredAt: 10),
                record(sessionName: "graftty-owner001", pid: 102, start: 10_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-owner001"],
            processStartTimes: [101: 10_001, 102: 10_002]
        )

        let owner = try #require(resolver.owner(for: ownerKey()))

        #expect(owner.paneSessionName == "graftty-owner001")
    }

    @Test("Records whose process identity is missing are ignored.")
    func recordsWhoseProcessIdentityIsMissingAreIgnored() throws {
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-missing1", pid: 101, start: nil, registeredAt: 10),
                record(sessionName: "graftty-owner001", pid: 102, start: 10_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-missing1", "graftty-owner001"],
            processStartTimes: [101: 10_001, 102: 10_002]
        )

        let owner = try #require(resolver.owner(for: ownerKey()))

        #expect(owner.paneSessionName == "graftty-owner001")
    }

    @Test("Reused PID with a different process start time is ignored.")
    func reusedPIDWithDifferentStartTimeIsIgnored() throws {
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-reused01", pid: 101, start: 10_001, registeredAt: 10),
                record(sessionName: "graftty-owner001", pid: 102, start: 10_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-reused01", "graftty-owner001"],
            processStartTimes: [101: 99_999, 102: 10_002]
        )

        let owner = try #require(resolver.owner(for: ownerKey()))

        #expect(owner.paneSessionName == "graftty-owner001")
    }

    @Test("Team, worktree, and runtime filters are respected.")
    func teamWorktreeAndRuntimeFiltersAreRespected() throws {
        let resolver = resolver(
            records: [
                record(teamID: "/other", sessionName: "graftty-other01", pid: 101, start: 10_001, registeredAt: 10),
                record(worktree: "/repo/.worktrees/bob", sessionName: "graftty-bob0001", pid: 102, start: 10_002, registeredAt: 20),
                record(runtime: .claude, sessionName: "graftty-claude1", pid: 103, start: 10_003, registeredAt: 30),
                record(sessionName: "graftty-owner001", pid: 104, start: 10_004, registeredAt: 40),
            ],
            liveSessions: ["graftty-other01", "graftty-bob0001", "graftty-claude1", "graftty-owner001"],
            processStartTimes: [101: 10_001, 102: 10_002, 103: 10_003, 104: 10_004]
        )

        let owner = try #require(resolver.owner(for: ownerKey()))

        #expect(owner.paneSessionName == "graftty-owner001")
    }

    @Test("Ties sort by pane session name, then PID.")
    func tiesSortByPaneSessionNameThenPID() throws {
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-b000000", pid: 1, start: 10_001, registeredAt: 10),
                record(sessionName: "graftty-a000000", pid: 20, start: 10_020, registeredAt: 10),
                record(sessionName: "graftty-a000000", pid: 10, start: 10_010, registeredAt: 10),
            ],
            liveSessions: ["graftty-a000000", "graftty-b000000"],
            processStartTimes: [1: 10_001, 10: 10_010, 20: 10_020]
        )

        let owner = try #require(resolver.owner(for: ownerKey()))

        #expect(owner.paneSessionName == "graftty-a000000")
        #expect(owner.pid == 10)
    }

    @Test("isOwner returns true only for the owner candidate.")
    func isOwnerReturnsTrueOnlyForOwnerCandidate() {
        let key = ownerKey()
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: 10_001, registeredAt: 10),
                record(sessionName: "graftty-later001", pid: 102, start: 10_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-owner001", "graftty-later001"],
            processStartTimes: [101: 10_001, 102: 10_002]
        )

        #expect(resolver.isOwner(
            candidate(key: key, sessionName: "graftty-owner001", pid: 101, start: 10_001),
            for: key
        ))
        #expect(!resolver.isOwner(
            candidate(key: key, sessionName: "graftty-later001", pid: 102, start: 10_002),
            for: key
        ))
        #expect(!resolver.isOwner(
            candidate(key: ownerKey(teamID: "/other"), sessionName: "graftty-owner001", pid: 101, start: 10_001),
            for: key
        ))
    }

    @Test("isOwner accepts a pane-only candidate for the current owner.")
    func isOwnerAcceptsPaneOnlyCandidateForCurrentOwner() {
        let key = ownerKey()
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: 10_001, registeredAt: 10),
            ],
            liveSessions: ["graftty-owner001"],
            processStartTimes: [101: 10_001]
        )

        #expect(resolver.isOwner(
            candidate(key: key, sessionName: "graftty-owner001", pid: nil, start: nil),
            for: key
        ))
    }

    @Test("isOwner rejects matching panes with mismatched supplied PID or start time.")
    func isOwnerRejectsMatchingPaneWithMismatchedSuppliedIdentity() {
        let key = ownerKey()
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: 10_001, registeredAt: 10),
            ],
            liveSessions: ["graftty-owner001"],
            processStartTimes: [101: 10_001]
        )

        #expect(!resolver.isOwner(
            candidate(key: key, sessionName: "graftty-owner001", pid: 999, start: 10_001),
            for: key
        ))
        #expect(!resolver.isOwner(
            candidate(key: key, sessionName: "graftty-owner001", pid: 101, start: 99_999),
            for: key
        ))
    }

    private func ownerKey(
        teamID: String = "/repo",
        worktree: String = "/repo/.worktrees/alice",
        runtime: TeamHookRuntime = .codex
    ) -> TeamDeliveryOwnerKey {
        TeamDeliveryOwnerKey(teamID: teamID, worktree: worktree, runtime: runtime)
    }

    private func record(
        teamID: String = "/repo",
        worktree: String = "/repo/.worktrees/alice",
        runtime: TeamHookRuntime = .codex,
        sessionName: String?,
        pid: Int32,
        start: Int64?,
        registeredAt: TimeInterval
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: teamID,
            worktree: worktree,
            runtime: runtime,
            paneSessionName: sessionName,
            pid: pid,
            processStartTimeMicroseconds: start,
            registeredAt: Date(timeIntervalSince1970: registeredAt)
        )
    }

    private func resolver(
        records: [TeamPresenceRecord],
        liveSessions: Set<String>,
        processStartTimes: [Int32: Int64]
    ) -> TeamDeliveryOwnershipResolver {
        TeamDeliveryOwnershipResolver(
            records: { records },
            liveness: FakeDeliveryLiveness(
                liveSessions: liveSessions,
                processStartTimes: processStartTimes
            )
        )
    }

    private func candidate(
        key: TeamDeliveryOwnerKey,
        sessionName: String?,
        pid: Int32?,
        start: Int64?
    ) -> TeamDeliveryOwnerCandidate {
        TeamDeliveryOwnerCandidate(
            key: key,
            paneSessionName: sessionName,
            pid: pid,
            processStartTimeMicroseconds: start,
            runtimeSessionID: nil
        )
    }
}

private struct FakeDeliveryLiveness: TeamDeliveryLivenessChecking {
    var liveSessions: Set<String> = []
    var processStartTimes: [Int32: Int64] = [:]

    func isLivePaneSession(_ sessionName: String) -> Bool {
        liveSessions.contains(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        processStartTimes[pid]
    }
}
