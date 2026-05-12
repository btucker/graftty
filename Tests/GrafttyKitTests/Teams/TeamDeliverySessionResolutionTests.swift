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

    @Test("Dead presence PID is not a delivery target even when the pane session is live.")
    func deadPresencePIDIsNotDeliveryTargetEvenWhenSessionIsLive() {
        let sessionName = "graftty-livepid"
        let records = [
            record(worktree: "/repo/.worktrees/alice", runtime: .codex, sessionName: sessionName, pid: 999_999),
        ]

        let resolved = TeamDeliverySessionResolution.codexSessionNames(
            in: "/repo/.worktrees/alice",
            records: records,
            isLiveSession: { $0 == sessionName },
            isPIDAlive: { _ in false }
        )

        #expect(resolved.isEmpty)
    }

    @Test("Live codex presence resolves by worktree, runtime, session, and PID.")
    func liveCodexPresenceResolvesByAllGates() {
        let liveSession = "graftty-live0001"
        let records = [
            record(worktree: "/repo/.worktrees/alice", runtime: .codex, sessionName: "graftty-old0001", pid: 101),
            record(worktree: "/repo/.worktrees/alice", runtime: .claude, sessionName: "graftty-claude01", pid: 102),
            record(worktree: "/repo/.worktrees/bob", runtime: .codex, sessionName: "graftty-bob00001", pid: 103),
            record(worktree: "/repo/.worktrees/alice", runtime: .codex, sessionName: liveSession, pid: 104),
        ]

        let resolved = TeamDeliverySessionResolution.codexSessionNames(
            in: "/repo/.worktrees/alice",
            records: records,
            isLiveSession: { $0 == liveSession },
            isPIDAlive: { $0 == 104 }
        )

        #expect(resolved == [liveSession])
    }

    private func record(
        worktree: String,
        runtime: TeamHookRuntime,
        sessionName: String?,
        pid: Int32
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo",
            worktree: worktree,
            runtime: runtime,
            paneSessionName: sessionName,
            pid: pid,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
