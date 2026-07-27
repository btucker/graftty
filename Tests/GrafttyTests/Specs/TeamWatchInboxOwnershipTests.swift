import Foundation
import Testing
@testable import GrafttyCLI
@testable import GrafttyKit

@Suite("Team watch-inbox ownership")
struct TeamWatchInboxOwnershipTests {
    @Test("Owner Claude session arms the inbox watcher.")
    func ownerClaudeSessionArmsWatcher() {
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: 10_001, registeredAt: 10),
                record(sessionName: "graftty-later001", pid: 102, start: 10_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-owner001", "graftty-later001"],
            processStartTimes: [101: 10_001, 102: 10_002]
        )

        let decision = TeamWatchInboxOwnership.decision(
            runtime: .claude,
            hookPayloadSessionID: "claude-session-owner",
            fallbackSessionID: { "fallback-session" },
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-owner001",
            resolver: resolver
        )

        #expect(decision.shouldArmWatcher)
        #expect(decision.sessionID == "claude-session-owner")
    }

    @Test("Non-owner Claude session does not arm the inbox watcher.")
    func nonOwnerClaudeSessionDoesNotArmWatcher() {
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: 10_001, registeredAt: 10),
                record(sessionName: "graftty-later001", pid: 102, start: 10_002, registeredAt: 20),
            ],
            liveSessions: ["graftty-owner001", "graftty-later001"],
            processStartTimes: [101: 10_001, 102: 10_002]
        )

        let decision = TeamWatchInboxOwnership.decision(
            runtime: .claude,
            hookPayloadSessionID: "claude-session-secondary",
            fallbackSessionID: { "fallback-session" },
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-later001",
            resolver: resolver
        )

        #expect(!decision.shouldArmWatcher)
        #expect(decision.sessionID == "claude-session-secondary")
    }

    @Test("Missing pane session name does not arm but still resolves the session ID.")
    func missingPaneSessionNameDoesNotArmButReturnsSessionID() {
        let resolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: 10_001, registeredAt: 10),
            ],
            liveSessions: ["graftty-owner001"],
            processStartTimes: [101: 10_001]
        )

        let decision = TeamWatchInboxOwnership.decision(
            runtime: .claude,
            hookPayloadSessionID: nil,
            fallbackSessionID: { "generated-session" },
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: nil,
            resolver: resolver
        )

        #expect(!decision.shouldArmWatcher)
        #expect(decision.sessionID == "generated-session")
    }

    @Test("Missing or mismatched process identity in presence does not arm.")
    func missingOrMismatchedProcessIdentityDoesNotArm() {
        let missingIdentityResolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: nil, registeredAt: 10),
            ],
            liveSessions: ["graftty-owner001"],
            processStartTimes: [101: 10_001]
        )
        let mismatchedIdentityResolver = resolver(
            records: [
                record(sessionName: "graftty-owner001", pid: 101, start: 10_001, registeredAt: 10),
            ],
            liveSessions: ["graftty-owner001"],
            processStartTimes: [101: 99_999]
        )

        let missingDecision = TeamWatchInboxOwnership.decision(
            runtime: .claude,
            hookPayloadSessionID: "claude-session",
            fallbackSessionID: { "fallback-session" },
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-owner001",
            resolver: missingIdentityResolver
        )
        let mismatchedDecision = TeamWatchInboxOwnership.decision(
            runtime: .claude,
            hookPayloadSessionID: "claude-session",
            fallbackSessionID: { "fallback-session" },
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-owner001",
            resolver: mismatchedIdentityResolver
        )

        #expect(!missingDecision.shouldArmWatcher)
        #expect(!mismatchedDecision.shouldArmWatcher)
    }

    @Test("CLI gate does not construct an InboxWatcher for non-owners.")
    func cliGateDoesNotConstructWatcherForNonOwners() {
        let decision = TeamWatchInboxOwnershipDecision(
            shouldArmWatcher: false,
            sessionID: "claude-session-secondary"
        )
        var constructedWatcher = false

        let watcher = TeamWatchInbox.makeWatcherIfOwner(decision: decision) {
            constructedWatcher = true
            return "watcher"
        }

        #expect(watcher == nil)
        #expect(!constructedWatcher)
    }

    @Test("""
    @spec TEAM-11.2: When a Claude asyncRewake inbox watcher reaches its \
    24-hour timeout without a message, the CLI shall exit cleanly without \
    writing a timeout diagnostic to the hook's stderr pipe.
    """)
    func timeoutIsCleanSilentTeardown() async {
        let result = await TeamWatchInbox.waitForOutcome(
            WatcherOutcome(),
            timeout: 0
        )

        #expect(result == WatcherOutcome.Result(exitCode: 0, stderr: ""))
    }

    @Test("""
    @spec TEAM-11.3: If a Claude asyncRewake inbox watcher resolves after \
    the hook's stderr reader has closed, the CLI shall discard the output \
    failure rather than terminate from SIGPIPE or an NSFileHandle exception.
    """)
    func brokenStderrPipeDoesNotCrash() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        defer { try? writer.close() }
        try pipe.fileHandleForReading.close()

        #expect(!TeamWatchInbox.writeToStderr("watch-inbox timeout\n", handle: writer))
    }

    @Test("Resolved watcher output still reaches an open stderr pipe.")
    func openStderrPipeReceivesOutput() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let message = "worktree message from main:\nhello\n"

        #expect(TeamWatchInbox.writeToStderr(message, handle: writer))
        try writer.close()

        let received = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: received, as: UTF8.self) == message)
    }

    private func record(
        teamID: String = "/repo",
        worktree: String = "/repo/.worktrees/alice",
        runtime: TeamHookRuntime = .claude,
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
            liveness: FakeWatchInboxLiveness(
                liveSessions: liveSessions,
                processStartTimes: processStartTimes
            )
        )
    }
}

private struct FakeWatchInboxLiveness: TeamDeliveryLivenessChecking {
    var liveSessions: Set<String>
    var processStartTimes: [Int32: Int64]

    func isLivePaneSession(_ sessionName: String) -> Bool {
        liveSessions.contains(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        processStartTimes[pid]
    }
}
