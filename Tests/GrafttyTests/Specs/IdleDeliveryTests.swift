import Testing
import Foundation
@testable import GrafttyKit

@Suite("IdleDeliveryService — Codex zmx-send poller")
struct IdleDeliveryTests {
    @Test("@spec TEAM-IDLE-2.1: While a Codex agent is registered and idle, the application shall poll its inbox and, when an unread message has been waiting for more than 60 seconds, deliver it via zmx-send.")
    func staleMessageDelivered() async throws {
        let env = try TestEnvironment.make()
        defer { env.cleanup() }

        try env.presence.write(
            TeamPresenceRecord(
                teamID: env.teamID,
                worktree: "wt-foo",
                runtime: .codex,
                pid: 1,
                registeredAt: Date()
            )
        )
        try env.appendOldMessage(
            id: "m1",
            recipientWorktree: "wt-foo",
            runtime: .codex,
            body: "hello",
            ageSeconds: 90
        )

        let recorder = TestNudgeRecorder()
        let service = IdleDeliveryService(
            presence: env.presence,
            inboxRoot: env.inboxRoot,
            inputState: ZmxInputState(),
            nudgeSender: recorder,
            eventLog: env.eventLog
        )

        await service.tick()

        let captured = await recorder.captured
        #expect(captured.count == 1)
        #expect(captured.first?.recipient.worktree == "wt-foo")
        #expect(captured.first?.messageIDs == ["m1"])
        #expect(captured.first?.message.contains("1 unread team message") == true)
    }

    @Test("@spec TEAM-IDLE-2.2: While the user has uncommitted typed bytes for a Codex agent's pane, the application shall not deliver a nudge to that agent.")
    func skipsWhileTyping() async throws {
        let env = try TestEnvironment.make()
        defer { env.cleanup() }

        try env.presence.write(
            TeamPresenceRecord(
                teamID: env.teamID,
                worktree: "wt-foo",
                runtime: .codex,
                pid: 1,
                registeredAt: Date()
            )
        )
        try env.appendOldMessage(
            id: "m1",
            recipientWorktree: "wt-foo",
            runtime: .codex,
            body: "hi",
            ageSeconds: 90
        )

        let inputState = ZmxInputState()
        // Default sessionLookup keys on the worktree name; mark that
        // session as mid-line so the gate trips.
        inputState.recordInput("typing".data(using: .utf8)!, forSession: "wt-foo")

        let recorder = TestNudgeRecorder()
        let service = IdleDeliveryService(
            presence: env.presence,
            inboxRoot: env.inboxRoot,
            inputState: inputState,
            nudgeSender: recorder,
            eventLog: env.eventLog
        )
        await service.tick()
        let captured = await recorder.captured
        #expect(captured.isEmpty)
    }

    @Test("@spec TEAM-IDLE-2.3: When the inbox state has not changed since a prior nudge, the application shall send at most one nudge per stale-state.")
    func debouncesNudges() async throws {
        let env = try TestEnvironment.make()
        defer { env.cleanup() }

        try env.presence.write(
            TeamPresenceRecord(
                teamID: env.teamID,
                worktree: "wt-foo",
                runtime: .codex,
                pid: 1,
                registeredAt: Date()
            )
        )
        try env.appendOldMessage(
            id: "m1",
            recipientWorktree: "wt-foo",
            runtime: .codex,
            body: "hi",
            ageSeconds: 90
        )

        let recorder = TestNudgeRecorder()
        let service = IdleDeliveryService(
            presence: env.presence,
            inboxRoot: env.inboxRoot,
            inputState: ZmxInputState(),
            nudgeSender: recorder,
            eventLog: env.eventLog
        )
        await service.tick()
        await service.tick()
        await service.tick()
        let captured = await recorder.captured
        #expect(captured.count == 1)
    }

    @Test("Skips messages younger than 60 seconds.")
    func skipsRecentMessages() async throws {
        let env = try TestEnvironment.make()
        defer { env.cleanup() }

        try env.presence.write(
            TeamPresenceRecord(
                teamID: env.teamID,
                worktree: "wt-foo",
                runtime: .codex,
                pid: 1,
                registeredAt: Date()
            )
        )
        try env.appendOldMessage(
            id: "m1",
            recipientWorktree: "wt-foo",
            runtime: .codex,
            body: "hi",
            ageSeconds: 30
        )

        let recorder = TestNudgeRecorder()
        let service = IdleDeliveryService(
            presence: env.presence,
            inboxRoot: env.inboxRoot,
            inputState: ZmxInputState(),
            nudgeSender: recorder,
            eventLog: env.eventLog
        )
        await service.tick()
        let captured = await recorder.captured
        #expect(captured.isEmpty)
    }

    @Test("Nudge emits a `nudgeSent` event into events.jsonl.")
    func nudgeEmitsEvent() async throws {
        let env = try TestEnvironment.make()
        defer { env.cleanup() }
        try env.presence.write(
            TeamPresenceRecord(
                teamID: env.teamID,
                worktree: "wt-foo",
                runtime: .codex,
                pid: 1,
                registeredAt: Date()
            )
        )
        try env.appendOldMessage(
            id: "m1",
            recipientWorktree: "wt-foo",
            runtime: .codex,
            body: "hi",
            ageSeconds: 90
        )

        let recorder = TestNudgeRecorder()
        let service = IdleDeliveryService(
            presence: env.presence,
            inboxRoot: env.inboxRoot,
            inputState: ZmxInputState(),
            nudgeSender: recorder,
            eventLog: env.eventLog
        )
        await service.tick()

        let logFile = env._eventLogRoot
            .appendingPathComponent(env.teamID)
            .appendingPathComponent("events.jsonl")
        let contents = (try? String(contentsOf: logFile)) ?? ""
        #expect(contents.contains("\"nudgeSent\""))
    }

    @Test("Ignores Claude registrants — Codex-only target for now.")
    func skipsClaudeAgents() async throws {
        let env = try TestEnvironment.make()
        defer { env.cleanup() }

        try env.presence.write(
            TeamPresenceRecord(
                teamID: env.teamID,
                worktree: "wt-bar",
                runtime: .claude,
                pid: 2,
                registeredAt: Date()
            )
        )
        try env.appendOldMessage(
            id: "m1",
            recipientWorktree: "wt-bar",
            runtime: .claude,
            body: "hi",
            ageSeconds: 90
        )

        let recorder = TestNudgeRecorder()
        let service = IdleDeliveryService(
            presence: env.presence,
            inboxRoot: env.inboxRoot,
            inputState: ZmxInputState(),
            nudgeSender: recorder,
            eventLog: env.eventLog
        )
        await service.tick()
        let captured = await recorder.captured
        #expect(captured.isEmpty)
    }

    /// Tmp-dir scaffold for presence + inbox roots, plus a helper that
    /// writes a backdated `TeamInboxMessage` directly to the JSONL so the
    /// service sees it as stale without us having to time-travel `Date()`.
    struct TestEnvironment {
        let teamID: String
        let presence: TeamPresenceStorage
        let inboxRoot: URL
        let eventLog: TeamEventLog
        let _eventLogRoot: URL
        let _root: URL

        static func make() throws -> TestEnvironment {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("graftty-idle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let presenceRoot = root.appendingPathComponent("presence", isDirectory: true)
            try FileManager.default.createDirectory(at: presenceRoot, withIntermediateDirectories: true)
            let inboxRoot = root.appendingPathComponent("inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
            let eventLogRoot = root.appendingPathComponent("events", isDirectory: true)
            try FileManager.default.createDirectory(at: eventLogRoot, withIntermediateDirectories: true)
            return TestEnvironment(
                teamID: "test-team",
                presence: TeamPresenceStorage(rootDirectory: presenceRoot),
                inboxRoot: inboxRoot,
                eventLog: TeamEventLog(rootDirectory: eventLogRoot),
                _eventLogRoot: eventLogRoot,
                _root: root
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: _root) }

        func appendOldMessage(
            id: String,
            recipientWorktree: String,
            runtime: TeamHookRuntime,
            body: String,
            ageSeconds: TimeInterval
        ) throws {
            let message = TeamInboxMessage(
                id: id,
                batchID: nil,
                createdAt: Date().addingTimeInterval(-ageSeconds),
                team: "TestTeam",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "sender", worktree: "wt-other", runtime: "codex"),
                to: TeamInboxEndpoint(member: recipientWorktree, worktree: recipientWorktree, runtime: runtime.rawValue),
                priority: .normal,
                kind: "team_message",
                body: body
            )
            let url = TeamInbox.messagesURLFor(rootDirectory: inboxRoot, teamID: teamID)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let line = try encoder.encode(message) + Data([0x0A])
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url)
            }
        }
    }
}

actor TestNudgeRecorder: NudgeSender {
    struct Captured {
        let recipient: TeamPresenceRecord
        let message: String
        let messageIDs: [String]
    }
    private(set) var captured: [Captured] = []

    func send(to recipient: TeamPresenceRecord, message: String, messageIDs: [String]) async {
        captured.append(Captured(recipient: recipient, message: message, messageIDs: messageIDs))
    }
}
