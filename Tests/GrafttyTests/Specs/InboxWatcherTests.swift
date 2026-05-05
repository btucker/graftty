import Testing
import Foundation
@testable import GrafttyKit

@Suite("InboxWatcher — exit on new message + PID-file supersede")
struct InboxWatcherTests {
    @Test("@spec TEAM-IDLE-1.4: When the watcher observes a new unread message addressed to its session, it shall exit with code 2 and a stderr summary.")
    func exitsWithCode2OnMessage() async throws {
        let tmpRoot = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let teamID = "team-x"
        let inboxRoot = tmpRoot.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        let pidRoot = tmpRoot.appendingPathComponent("teams", isDirectory: true)

        let inbox = TeamInbox(rootDirectory: inboxRoot)
        let outcome = WatcherOutcome()

        let recipient = InboxWatcher.Recipient(member: "wt-foo", runtime: .claude)
        let watcher = InboxWatcher(
            sessionID: "test-session",
            recipient: recipient,
            teamID: teamID,
            inboxRootDirectory: inboxRoot,
            outcome: outcome,
            pidFileRoot: pidRoot
        )

        let runTask = Task.detached { await watcher.runUntilSignal() }
        defer { runTask.cancel() }

        // Give the watcher a moment to register PID and attach the FSEvents source.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Append a message addressed to this watcher's recipient.
        _ = try inbox.appendMessage(
            teamID: teamID,
            teamName: "TeamX",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "other", worktree: "wt-other", runtime: "claude"),
            to: TeamInboxEndpoint(member: "wt-foo", worktree: "wt-foo", runtime: "claude"),
            priority: .normal,
            body: "new message body!"
        )

        let result = try await outcome.wait(timeout: 3.0)
        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("new message body!"))
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
            recipient: .init(member: "wt-foo", runtime: .claude),
            teamID: teamID,
            inboxRootDirectory: inboxRoot,
            outcome: outcome,
            pidFileRoot: pidRoot
        )

        let runTask = Task.detached { await watcher.runUntilSignal() }
        defer { runTask.cancel() }

        // Give the watcher time to supersede + write its own PID.
        try await Task.sleep(nanoseconds: 600_000_000)

        // PID file now contains our process's PID, not the prior child's.
        let nowOnDisk = try String(contentsOf: priorPidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        #expect(nowOnDisk == String(ourPID))

        // Prior child process should have been SIGTERMed and reaped.
        prior.waitUntilExit()
        #expect(!prior.isRunning)
    }

    private func makeTmpDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
