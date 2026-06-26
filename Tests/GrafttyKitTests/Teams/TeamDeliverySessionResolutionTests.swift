import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team delivery session resolution")
struct TeamDeliverySessionResolutionTests {
    @Test("Late Stop for an old session does not target the fresh session in the same pane slot.")
    func lateStopForOldSessionDoesNotDeliverToFreshSessionInSameSlot() {
        let oldSessionName = "graftty-aaaaaaaa"
        let newSessionName = "graftty-bbbbbbbb"

        let resolved = TeamDeliverySessionResolution.stopSessionName(
            runtime: TeamHookRuntime.codex.rawValue,
            paneSessionName: oldSessionName,
            isLiveSession: { $0 == newSessionName }
        )

        #expect(resolved == nil)
    }

    @Test("Codex session names returns only the owner session, not every live session.")
    func codexSessionNamesReturnsOnlyOwnerSession() {
        let ownerSession = "graftty-owner001"
        let laterSession = "graftty-later001"
        let records = [
            record(sessionName: ownerSession, pid: 101, start: 10_001, registeredAt: 10),
            record(sessionName: laterSession, pid: 102, start: 10_002, registeredAt: 20),
        ]

        let resolved = TeamDeliverySessionResolution.codexSessionNames(
            teamID: "/repo",
            in: "/repo/.worktrees/alice",
            records: records,
            isLiveSession: { $0 == ownerSession || $0 == laterSession },
            processStartTimeMicroseconds: { [101: 10_001, 102: 10_002][$0] }
        )

        #expect(resolved == [ownerSession])
    }

    @Test("Earlier record wins even when a later record is also live.")
    func earlierRecordWinsEvenWhenLaterRecordIsLive() {
        let earlierSession = "graftty-earlier1"
        let laterSession = "graftty-later001"
        let records = [
            record(sessionName: laterSession, pid: 101, start: 10_001, registeredAt: 200),
            record(sessionName: earlierSession, pid: 102, start: 10_002, registeredAt: 100),
        ]

        let resolved = TeamDeliverySessionResolution.codexSessionNames(
            teamID: "/repo",
            in: "/repo/.worktrees/alice",
            records: records,
            isLiveSession: { $0 == earlierSession || $0 == laterSession },
            processStartTimeMicroseconds: { [101: 10_001, 102: 10_002][$0] }
        )

        #expect(resolved == [earlierSession])
    }

    @Test("Missing or mismatched process start times exclude a record.")
    func missingOrMismatchedProcessStartTimesExcludeRecords() {
        let validSession = "graftty-valid001"
        let records = [
            record(sessionName: "graftty-missing1", pid: 101, start: nil, registeredAt: 10),
            record(sessionName: "graftty-stale001", pid: 102, start: 10_002, registeredAt: 20),
            record(sessionName: validSession, pid: 103, start: 10_003, registeredAt: 30),
        ]

        let resolved = TeamDeliverySessionResolution.codexSessionNames(
            teamID: "/repo",
            in: "/repo/.worktrees/alice",
            records: records,
            isLiveSession: { _ in true },
            processStartTimeMicroseconds: { [101: 10_001, 102: 99_999, 103: 10_003][$0] }
        )

        #expect(resolved == [validSession])
    }

    @Test("Codex session resolution still filters by team, worktree, runtime, and live session.")
    func codexSessionResolutionStillFiltersByTeamWorktreeRuntimeAndLiveSession() {
        let liveSession = "graftty-live0001"
        let records = [
            record(teamID: "/other", sessionName: "graftty-other01", pid: 101, start: 10_001, registeredAt: 10),
            record(worktree: "/repo/.worktrees/bob", sessionName: "graftty-bob00001", pid: 102, start: 10_002, registeredAt: 20),
            record(runtime: .claude, sessionName: "graftty-claude01", pid: 103, start: 10_003, registeredAt: 30),
            record(sessionName: "graftty-dead0001", pid: 104, start: 10_004, registeredAt: 40),
            record(sessionName: liveSession, pid: 105, start: 10_005, registeredAt: 50),
        ]

        let resolved = TeamDeliverySessionResolution.codexSessionNames(
            teamID: "/repo",
            in: "/repo/.worktrees/alice",
            records: records,
            isLiveSession: { $0 == liveSession },
            processStartTimeMicroseconds: { [101: 10_001, 102: 10_002, 103: 10_003, 104: 10_004, 105: 10_005][$0] }
        )

        #expect(resolved == [liveSession])
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
}
