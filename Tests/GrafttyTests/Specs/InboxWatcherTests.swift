import Testing
import Foundation
@testable import GrafttyKit

@Suite("InboxWatcher — exit on new message + PID-file supersede")
struct InboxWatcherTests {
    @Test("@spec TEAM-IDLE-1.4: When the watcher observes a new unread message whose canonical `to.worktree` equals its recipient worktree, it shall exit with code 2 and a stderr summary naming the sender's canonical worktree address; branch-derived member names shall remain display metadata and shall not control routing.")
    func exitsWithCode2OnMessage() async throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let teamID = "team-x"
        let inboxRoot = tmpRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let pidRoot = tmpRoot.appendingPathComponent("teams", isDirectory: true)

        let inbox = TeamInbox(rootDirectory: inboxRoot)
        let outcome = WatcherOutcome()

        let recipient = InboxWatcher.Recipient(
            member: "wt-foo",
            worktree: "wt-foo-path",
            runtime: .claude
        )
        let watcher = InboxWatcher(
            sessionID: "test-session",
            recipient: recipient,
            teamID: teamID,
            inboxRootDirectory: inboxRoot,
            outcome: outcome,
            pidFileRoot: pidRoot,
            eventLog: TeamEventLog(rootDirectory: tmpRoot.appendingPathComponent("events", isDirectory: true))
        )

        let runTask = Task.detached { await watcher.runUntilSignal() }
        defer { runTask.cancel() }

        // Wait for the watcher to register its PID and for the FSEvents
        // observer to fire its initial callback (i.e., it's actually
        // listening). Avoids Task.sleep, which stretches under CI load.
        await watcher.whenReady()

        // Append a message addressed to this watcher's recipient.
        _ = try inbox.appendMessage(
            teamID: teamID,
            teamName: "TeamX",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "other", worktree: "wt-other", runtime: "claude"),
            to: TeamInboxEndpoint(member: "renamed-display", worktree: "wt-foo-path", runtime: "claude"),
            priority: .normal,
            body: "new message body!"
        )

        let result = try await outcome.wait(timeout: 3.0)
        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("new message body!"))
        #expect(result.stderr.contains("from wt-other:"))
    }

    @Test("Watcher wakes for a message queued after SessionStart but present in its first snapshot")
    func initialSnapshotUsesPersistedSessionCursor() async throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let teamID = "team-x"
        let inboxRoot = tmpRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let pidRoot = tmpRoot.appendingPathComponent("teams", isDirectory: true)
        let inbox = TeamInbox(rootDirectory: inboxRoot)

        try inbox.writeCursor(
            TeamInboxCursor(
                sessionID: "test-session",
                worktree: "wt-foo-path",
                runtime: TeamHookRuntime.claude.rawValue,
                lastSeenID: nil
            ),
            teamID: teamID
        )
        _ = try inbox.appendMessage(
            teamID: teamID,
            teamName: "TeamX",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "other", worktree: "wt-other", runtime: "claude"),
            to: TeamInboxEndpoint(member: "wt-foo", worktree: "wt-foo-path", runtime: "claude"),
            priority: .normal,
            body: "queued during startup"
        )

        let outcome = WatcherOutcome()
        let watcher = InboxWatcher(
            sessionID: "test-session",
            recipient: .init(member: "wt-foo", worktree: "wt-foo-path", runtime: .claude),
            teamID: teamID,
            inboxRootDirectory: inboxRoot,
            outcome: outcome,
            pidFileRoot: pidRoot,
            eventLog: TeamEventLog(rootDirectory: tmpRoot.appendingPathComponent("events", isDirectory: true))
        )
        let runTask = Task.detached { await watcher.runUntilSignal() }
        defer { runTask.cancel() }

        let result = try await outcome.wait(timeout: 3.0)
        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("queued during startup"))
    }

    @Test("""
    @spec TEAM-IDLE-1.5: When an asyncRewake watcher claims an unread message, the application shall advance that session's cursor and the shared worktree watermark before waking Claude so a re-armed or competing watcher cannot deliver the same durable message again.
    """)
    func deliveredMessageCannotWakeRearmedWatcher() async throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let teamID = "team-x"
        let sessionID = "test-session"
        let worktree = "wt-foo-path"
        let inboxRoot = tmpRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let inbox = TeamInbox(rootDirectory: inboxRoot)
        let originalTask = try appendMessage(
            to: inbox,
            teamID: teamID,
            worktree: worktree,
            body: "original task"
        )
        try seedSession(
            in: inbox,
            teamID: teamID,
            sessionID: sessionID,
            worktree: worktree,
            lastSeenID: originalTask.id
        )
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: worktree,
                lastDeliveredToAnySessionID: originalTask.id
            ),
            teamID: teamID
        )

        let firstOutcome = WatcherOutcome()
        let firstWatcher = makeWatcher(
            sessionID: sessionID,
            worktree: worktree,
            teamID: teamID,
            inboxRoot: inboxRoot,
            tmpRoot: tmpRoot,
            outcome: firstOutcome
        )
        let firstRun = Task.detached { await firstWatcher.runUntilSignal() }
        await firstWatcher.whenReady()

        let delivered = try appendMessage(
            to: inbox,
            teamID: teamID,
            worktree: worktree,
            body: "deliver exactly once",
            runtime: TeamHookRuntime.claude.rawValue
        )
        let firstResult = try await firstOutcome.wait(timeout: 3.0)
        #expect(firstResult.stderr.contains("deliver exactly once"))
        #expect(try inbox.cursor(teamID: teamID, sessionID: sessionID)?.lastSeenID == delivered.id)
        #expect(
            try inbox.worktreeWatermark(teamID: teamID, worktree: worktree)?
                .lastDeliveredToAnySessionID == delivered.id
        )
        firstRun.cancel()
        await firstRun.value

        let secondOutcome = WatcherOutcome()
        let secondWatcher = makeWatcher(
            sessionID: sessionID,
            worktree: worktree,
            teamID: teamID,
            inboxRoot: inboxRoot,
            tmpRoot: tmpRoot,
            outcome: secondOutcome
        )
        let secondRun = Task.detached { await secondWatcher.runUntilSignal() }
        defer { secondRun.cancel() }
        await secondWatcher.whenReady()

        do {
            _ = try await secondOutcome.wait(timeout: 0.5)
            Issue.record("the re-armed watcher re-delivered an already claimed message")
        } catch WatcherOutcome.WaitError.timeout {
            // Expected: the durable row was already consumed.
        }
    }

    @Test("Competing sessions cannot both claim the same durable message")
    func competingSessionsClaimOnce() async throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let teamID = "team-x"
        let worktree = "wt-foo-path"
        let inboxRoot = tmpRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let inbox = TeamInbox(rootDirectory: inboxRoot)
        for sessionID in ["session-a", "session-b"] {
            try seedSession(
                in: inbox,
                teamID: teamID,
                sessionID: sessionID,
                worktree: worktree,
                lastSeenID: nil
            )
        }

        let outcomeA = WatcherOutcome()
        let outcomeB = WatcherOutcome()
        let watcherA = makeWatcher(
            sessionID: "session-a",
            worktree: worktree,
            teamID: teamID,
            inboxRoot: inboxRoot,
            tmpRoot: tmpRoot,
            outcome: outcomeA
        )
        let watcherB = makeWatcher(
            sessionID: "session-b",
            worktree: worktree,
            teamID: teamID,
            inboxRoot: inboxRoot,
            tmpRoot: tmpRoot,
            outcome: outcomeB
        )
        let runA = Task.detached { await watcherA.runUntilSignal() }
        let runB = Task.detached { await watcherB.runUntilSignal() }
        defer {
            runA.cancel()
            runB.cancel()
        }
        await watcherA.whenReady()
        await watcherB.whenReady()

        let message = try appendMessage(
            to: inbox,
            teamID: teamID,
            worktree: worktree,
            body: "one claimant",
            runtime: TeamHookRuntime.claude.rawValue
        )

        async let resultA = try? outcomeA.wait(timeout: 1.5)
        async let resultB = try? outcomeB.wait(timeout: 1.5)
        let results = await [resultA, resultB].compactMap { $0 }
        #expect(results.count == 1)
        #expect(
            try inbox.worktreeWatermark(teamID: teamID, worktree: worktree)?
                .lastDeliveredToAnySessionID == message.id
        )
        let claimedCursors = try ["session-a", "session-b"].compactMap {
            try inbox.cursor(teamID: teamID, sessionID: $0)?.lastSeenID
        }
        #expect(claimedCursors == [message.id])
    }

    @Test("Runtime filtering preserves an earlier non-runtime-targeted message")
    func runtimeFilteringPreservesInboxOrder() async throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let teamID = "team-x"
        let sessionID = "test-session"
        let worktree = "wt-foo-path"
        let inboxRoot = tmpRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let inbox = TeamInbox(rootDirectory: inboxRoot)
        try seedSession(
            in: inbox,
            teamID: teamID,
            sessionID: sessionID,
            worktree: worktree,
            lastSeenID: nil
        )
        let shared = try appendMessage(
            to: inbox,
            teamID: teamID,
            worktree: worktree,
            body: "earlier shared message"
        )
        _ = try appendMessage(
            to: inbox,
            teamID: teamID,
            worktree: worktree,
            body: "later Claude message",
            runtime: TeamHookRuntime.claude.rawValue
        )

        let outcome = WatcherOutcome()
        let watcher = makeWatcher(
            sessionID: sessionID,
            worktree: worktree,
            teamID: teamID,
            inboxRoot: inboxRoot,
            tmpRoot: tmpRoot,
            outcome: outcome
        )
        let runTask = Task.detached { await watcher.runUntilSignal() }
        defer { runTask.cancel() }

        let result = try await outcome.wait(timeout: 3.0)
        #expect(result.stderr.contains("earlier shared message"))
        #expect(!result.stderr.contains("later Claude message"))
        #expect(try inbox.cursor(teamID: teamID, sessionID: sessionID)?.lastSeenID == shared.id)
    }

    @Test("@spec TEAM-IDLE-1.3: Watcher writes a PID file at <root>/<teamID>/watchers/<session>.<runtime>.pid and SIGTERMs any prior PID it finds.")
    func supersedesPriorWatcher() async throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let teamID = "team-x"
        let inboxRoot = tmpRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let pidRoot = tmpRoot.appendingPathComponent("teams", isDirectory: true)

        // Spawn a real, signal-killable child process to stand in for the
        // prior watcher, write its PID where the new watcher will look.
        let prior = Process()
        prior.executableURL = URL(fileURLWithPath: "/bin/sleep")
        prior.arguments = ["30"]
        try prior.run()
        let priorPID = prior.processIdentifier

        let priorPidFile = pidRoot
            .appendingPathComponent(teamID, isDirectory: true)
            .appendingPathComponent("watchers", isDirectory: true)
            .appendingPathComponent("test-session.claude.pid")
        try FileManager.default.createDirectory(
            at: priorPidFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try String(priorPID).write(to: priorPidFile, atomically: true, encoding: .utf8)

        let outcome = WatcherOutcome()
        let watcher = InboxWatcher(
            sessionID: "test-session",
            recipient: .init(member: "wt-foo", worktree: "wt-foo-path", runtime: .claude),
            teamID: teamID,
            inboxRootDirectory: inboxRoot,
            outcome: outcome,
            pidFileRoot: pidRoot,
            eventLog: TeamEventLog(rootDirectory: tmpRoot.appendingPathComponent("events", isDirectory: true))
        )

        let runTask = Task.detached { await watcher.runUntilSignal() }
        defer { runTask.cancel() }

        // Wait for the watcher to supersede the prior PID, write its own
        // PID, and have the FSEvents observer attach. Replaces a
        // Task.sleep that stretched arbitrarily on contended CI executors.
        await watcher.whenReady()

        // PID file now contains our process's PID, not the prior child's.
        let nowOnDisk = try String(contentsOf: priorPidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        #expect(nowOnDisk == String(ourPID))

        // Prior child process should have been SIGTERMed and reaped.
        prior.waitUntilExit()
        #expect(!prior.isRunning)
    }

    private func makeWatcher(
        sessionID: String,
        worktree: String,
        teamID: String,
        inboxRoot: URL,
        tmpRoot: URL,
        outcome: WatcherOutcome
    ) -> InboxWatcher {
        InboxWatcher(
            sessionID: sessionID,
            recipient: .init(member: "wt-foo", worktree: worktree, runtime: .claude),
            teamID: teamID,
            inboxRootDirectory: inboxRoot,
            outcome: outcome,
            pidFileRoot: tmpRoot.appendingPathComponent("teams", isDirectory: true),
            eventLog: TeamEventLog(
                rootDirectory: tmpRoot.appendingPathComponent("events", isDirectory: true)
            )
        )
    }

    private func seedSession(
        in inbox: TeamInbox,
        teamID: String,
        sessionID: String,
        worktree: String,
        lastSeenID: String?
    ) throws {
        try inbox.writeCursor(
            TeamInboxCursor(
                sessionID: sessionID,
                worktree: worktree,
                runtime: TeamHookRuntime.claude.rawValue,
                lastSeenID: lastSeenID
            ),
            teamID: teamID
        )
    }

    private func appendMessage(
        to inbox: TeamInbox,
        teamID: String,
        worktree: String,
        body: String,
        runtime: String? = nil
    ) throws -> TeamInboxMessage {
        try inbox.appendMessage(
            teamID: teamID,
            teamName: "TeamX",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "other", worktree: "wt-other", runtime: runtime),
            to: TeamInboxEndpoint(member: "wt-foo", worktree: worktree, runtime: runtime),
            priority: .normal,
            body: body
        )
    }

    private func makeTmpDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
