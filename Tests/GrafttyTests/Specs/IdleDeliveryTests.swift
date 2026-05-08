import Foundation
import Testing
@testable import GrafttyKit

@Suite("IdleDeliveryService — event-driven idle delivery")
struct IdleDeliveryServiceTests {
    @Test("@spec TEAM-IDLE-2.1: While the worktree state is idle, onStop with pending messages calls the nudge sender and advances the watermark.")
    func onStopIdleWithPendingDelivers() async throws {
        let f = try Fixture()
        let id = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)

        #expect(f.sender.calls.count == 1)
        #expect(f.sender.calls[0].messageIDs == [id])
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == id)
    }

    @Test("@spec TEAM-IDLE-2.2: While the worktree state is user_engaged, onStop defers — no nudge, no watermark advance.")
    func onStopUserEngagedDefers() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: f.frozen)

        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)

        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("@spec TEAM-IDLE-2.3: A second onStop with same state and watermark does not redeliver.")
    func dedupedOnStop() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        #expect(f.sender.calls.count == 1)
    }

    @Test("@spec TEAM-IDLE-2.4: With no pane (paneID nil), onStop does not call the sender.")
    func noPaneSkipsAndLogs() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: nil)
        #expect(f.sender.calls.isEmpty)
    }

    @Test("Claude runtime is skipped — asyncRewake watcher already covers it; zmx-send would double-deliver.")
    func claudeRuntimeIsSkipped() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "claude")
        f.state.handleStop(worktree: f.worktree, runtime: "claude", lastInputAt: nil)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "claude", paneID: f.paneID)
        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "claude") == nil)
    }

    @Test("@spec TEAM-IDLE-2.8: When the recipient pane's runtime cannot be confirmed as 'codex' (no SessionStart fired and no presence record), the application shall not deliver pending messages via zmx keys-input — non-codex terminals (shells, editors, claude, etc.) must never receive typed message text.")
    func unconfirmedRuntimeSkipsKeysInput() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, runtime: nil, paneID: f.paneID)
        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("@spec TEAM-IDLE-2.8: With a nil runtime, onStop also skips — the keys-input gate is symmetric across triggers.")
    func unconfirmedRuntimeOnStopSkips() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: nil, paneID: f.paneID)
        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("onMessageArrival delivers when idle; is a no-op when active.")
    func onMessageArrivalGatedByState() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")

        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        #expect(f.sender.calls.isEmpty, "active state must not deliver")

        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        #expect(f.sender.calls.count == 1)
    }

    @Test("Unknown state with a resolved pane delivers — covers the post-graftty-restart case where SessionStart hasn't fired yet for an existing Codex session.")
    func unknownStateWithPaneDelivers() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        // No handleSessionStart / handleStop call — state stays .unknown.
        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)
        #expect(f.sender.calls.count == 1)
    }

    @Test("@spec TEAM-IDLE-2.7: Nudge attempts append zmxNudgeAttempt rows to events.jsonl via TeamEventLog, never via TeamEventDispatcher.")
    func nudgeLogsToEventLog() async throws {
        let f = try FixtureWithEventLog()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(team: f.teamID, worktree: f.worktree, runtime: "codex", paneID: f.paneID)

        let events = try f.readEvents()
        #expect(events.count == 1)
        #expect(events[0].kind == .zmxNudgeAttempt)
        #expect(events[0].detail["outcome"] == "sent")
        #expect(events[0].detail["trigger"] == "stop")
    }

    final class StubSender: NudgeSender, @unchecked Sendable {
        struct Call { let paneID: UUID; let text: String; let messageIDs: [String] }
        var calls: [Call] = []
        func send(paneID: UUID, message: String, messageIDs: [String]) async {
            calls.append(.init(paneID: paneID, text: message, messageIDs: messageIDs))
        }
    }

    struct Fixture {
        let teamID = "/repo"
        let worktree = "/repo/.worktrees/alice"
        let paneID = UUID()
        let sender = StubSender()
        let state: WorktreeAgentStateRegistry
        let inbox: TeamInbox
        let service: IdleDeliveryService
        let frozen: Date

        init() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-idle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.frozen = Date(timeIntervalSince1970: 1_700_000_000)
            let frozen = self.frozen
            self.state = WorktreeAgentStateRegistry(now: { frozen })
            self.inbox = TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { frozen })
            self.service = IdleDeliveryService(
                inbox: inbox,
                state: state,
                nudgeSender: sender,
                eventLog: nil,
                now: { frozen }
            )
        }

        func appendUnread(body: String) throws -> String {
            let msg = try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
                to: TeamInboxEndpoint(member: "alice", worktree: worktree, runtime: nil),
                priority: .normal,
                kind: "team_message",
                body: body
            )
            return msg.id
        }
    }

    struct FixtureWithEventLog {
        let teamID = "/repo"
        let worktree = "/repo/.worktrees/alice"
        let paneID = UUID()
        let sender = StubSender()
        let state: WorktreeAgentStateRegistry
        let inbox: TeamInbox
        let service: IdleDeliveryService
        let eventLog: TeamEventLog
        let frozen: Date
        let rootDir: URL

        init() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-idle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.rootDir = dir
            self.frozen = Date(timeIntervalSince1970: 1_700_000_000)
            let frozen = self.frozen
            self.state = WorktreeAgentStateRegistry(now: { frozen })
            self.inbox = TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { frozen })
            self.eventLog = TeamEventLog(rootDirectory: dir)
            self.service = IdleDeliveryService(
                inbox: inbox,
                state: state,
                nudgeSender: sender,
                eventLog: eventLog,
                now: { frozen }
            )
        }

        func appendUnread(body: String) throws -> String {
            let msg = try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
                to: TeamInboxEndpoint(member: "alice", worktree: worktree, runtime: nil),
                priority: .normal,
                kind: "team_message",
                body: body
            )
            return msg.id
        }

        func readEvents() throws -> [TeamEvent] {
            let eventsPath = rootDir
                .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
                .appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: eventsPath.path) else { return [] }
            let data = try Data(contentsOf: eventsPath)
            let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try lines.map { line in
                try decoder.decode(TeamEvent.self, from: Data(line))
            }
        }
    }
}
