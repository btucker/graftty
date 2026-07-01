import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("GrafttyApp — Codex Stop delivery ownership")
struct CodexStopDeliveryOwnershipTests {
    @Test("Owner Codex Stop updates from the stopping pane and delivers to owner sessions.")
    func ownerStopTargetsOwnerSessions() {
        var requestedTeam: String?
        var requestedWorktree: String?

        let plan = GrafttyApp.codexStopDeliveryPlan(
            team: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: TeamHookRuntime.codex.rawValue,
            paneSessionName: "graftty-owner",
            isLiveSession: { $0 == "graftty-owner" || $0 == "graftty-secondary" },
            codexSessionNamesIn: { team, worktree in
                requestedTeam = team
                requestedWorktree = worktree
                return ["graftty-owner"]
            }
        )

        #expect(plan.shouldUpdateState)
        #expect(plan.liveSessionName == "graftty-owner")
        #expect(plan.deliverySessionNames == ["graftty-owner"])
        #expect(requestedTeam == "/repo")
        #expect(requestedWorktree == "/repo/.worktrees/alice")
    }

    @Test("Non-owner Codex Stop does not update owner delivery state or target owner sessions.")
    func nonOwnerStopDoesNotTargetOwnerSessions() {
        let plan = GrafttyApp.codexStopDeliveryPlan(
            team: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: TeamHookRuntime.codex.rawValue,
            paneSessionName: "graftty-secondary",
            isLiveSession: { $0 == "graftty-owner" || $0 == "graftty-secondary" },
            codexSessionNamesIn: { _, _ in ["graftty-owner"] }
        )

        #expect(!plan.shouldUpdateState)
        #expect(plan.liveSessionName == "graftty-secondary")
        #expect(plan.deliverySessionNames == [])
    }

    @Test("Stale or missing-pane Codex Stop does not resolve owner delivery sessions.")
    func staleStopDoesNotTargetOwnerSessions() {
        var didResolveOwnerSessions = false

        let plan = GrafttyApp.codexStopDeliveryPlan(
            team: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: TeamHookRuntime.codex.rawValue,
            paneSessionName: "graftty-stale",
            isLiveSession: { _ in false },
            codexSessionNamesIn: { _, _ in
                didResolveOwnerSessions = true
                return ["graftty-owner"]
            }
        )

        #expect(!plan.shouldUpdateState)
        #expect(plan.liveSessionName == nil)
        #expect(plan.deliverySessionNames == [])
        #expect(!didResolveOwnerSessions)
    }

    @Test("Non-owner Codex lifecycle hooks do not update shared owner delivery state.")
    func nonOwnerLifecycleDoesNotUpdateDeliveryState() {
        let shouldUpdate = GrafttyApp.shouldUpdateDeliveryStateForHook(
            team: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: TeamHookRuntime.codex.rawValue,
            paneSessionName: "graftty-secondary",
            codexSessionNamesIn: { _, _ in ["graftty-owner"] }
        )

        #expect(!shouldUpdate)
    }
}

@Suite("IdleDeliveryService — event-driven idle delivery")
struct IdleDeliveryServiceTests {
    @Test("@spec TEAM-IDLE-2.11: sessionNames.count == 2 → both sessions receive nudges; watermark advances exactly once.")
    func fanOutToTwoSessions() async throws {
        let f = try Fixture()
        let id = try f.appendUnread(body: "hello")
        let sessionA = "graftty-sessiona"
        let sessionB = "graftty-sessionb"
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, sessionNames: [sessionA, sessionB])

        #expect(f.sender.calls.count == 2)
        #expect(Set(f.sender.calls.map(\.sessionName)) == Set([sessionA, sessionB]))
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == id)
    }

    @Test("When every nudge send fails, attempts are recorded but the zmx watermark is not advanced.")
    func failedNudgesDoNotAdvanceWatermark() async throws {
        let f = try Fixture(sendResults: [false, false])
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(
            team: f.teamID,
            worktree: f.worktree,
            sessionNames: ["graftty-sessiona", "graftty-sessionb"]
        )

        #expect(f.sender.calls.count == 2)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("When at least one nudge send succeeds, the zmx watermark advances.")
    func successfulNudgeAdvancesWatermark() async throws {
        let f = try Fixture(sendResults: [false, true])
        let id = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(
            team: f.teamID,
            worktree: f.worktree,
            sessionNames: ["graftty-sessiona", "graftty-sessionb"]
        )

        #expect(f.sender.calls.count == 2)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == id)
        #expect(try f.inbox.worktreeWatermark(
            teamID: f.teamID,
            worktree: f.worktree
        )?.lastDeliveredToAnySessionID == id)
    }

    @Test("Messages already delivered through hook worktree watermark are not sent again by zmx idle delivery.")
    func worktreeWatermarkSuppressesDuplicateZmxDelivery() async throws {
        let f = try Fixture()
        let id = try f.appendUnread(body: "hello")
        try f.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: f.worktree,
                lastDeliveredToAnySessionID: id
            ),
            teamID: f.teamID
        )
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])

        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("@spec TEAM-IDLE-2.12: sessionNames is empty → no nudge, no watermark advance.")
    func emptySessionNamesSkips() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, sessionNames: [])
        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("@spec TEAM-IDLE-2.1: While the worktree state is idle, onStop with pending messages calls the nudge sender and advances the watermark.")
    func onStopIdleWithPendingDelivers() async throws {
        let f = try Fixture()
        let id = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])

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

        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])

        #expect(f.sender.calls.isEmpty)
        #expect(try f.inbox.zmxWatermark(teamID: f.teamID, worktree: f.worktree, runtime: "codex") == nil)
    }

    @Test("@spec TEAM-IDLE-2.3: A second onStop with same state and watermark does not redeliver.")
    func dedupedOnStop() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])
        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])
        #expect(f.sender.calls.count == 1)
    }

    @Test("@spec TEAM-IDLE-2.4: With no target session, onStop does not call the sender.")
    func noSessionSkipsAndLogs() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [])
        #expect(f.sender.calls.isEmpty)
    }

    @Test("onMessageArrival delivers when idle; is a no-op when active.")
    func onMessageArrivalGatedByState() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")

        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])
        #expect(f.sender.calls.isEmpty, "active state must not deliver")

        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)
        await f.service.onMessageArrival(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])
        #expect(f.sender.calls.count == 1)
    }

    @Test("Unknown state with a resolved pane delivers — covers the post-graftty-restart case where SessionStart hasn't fired yet for an existing Codex session.")
    func unknownStateWithPaneDelivers() async throws {
        let f = try Fixture()
        _ = try f.appendUnread(body: "hello")
        // No handleSessionStart / handleStop call — state stays .unknown.
        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])
        #expect(f.sender.calls.count == 1)
    }

    @Test("@spec TEAM-IDLE-2.7: Nudge attempts append zmxNudgeAttempt rows to events.jsonl via TeamEventLog, never via TeamEventDispatcher.")
    func nudgeLogsToEventLog() async throws {
        let f = try FixtureWithEventLog()
        _ = try f.appendUnread(body: "hello")
        f.state.handleSessionStart(worktree: f.worktree, runtime: "codex")
        f.state.handleStop(worktree: f.worktree, runtime: "codex", lastInputAt: nil)

        await f.service.onStop(team: f.teamID, worktree: f.worktree, sessionNames: [f.sessionName])

        let events = try f.readEvents()
        #expect(events.count == 1)
        #expect(events[0].kind == .zmxNudgeAttempt)
        #expect(events[0].detail["outcome"] == "sent")
        #expect(events[0].detail["trigger"] == "stop")
    }

    final class StubSender: NudgeSender, @unchecked Sendable {
        struct Call { let sessionName: String; let text: String; let messageIDs: [String] }
        var calls: [Call] = []
        var sendResults: [Bool]

        init(sendResults: [Bool] = []) {
            self.sendResults = sendResults
        }

        func send(sessionName: String, message: String, messageIDs: [String]) async -> Bool {
            calls.append(.init(sessionName: sessionName, text: message, messageIDs: messageIDs))
            if sendResults.isEmpty { return true }
            return sendResults.removeFirst()
        }
    }

    struct Fixture {
        let teamID = "/repo"
        let worktree = "/repo/.worktrees/alice"
        let sessionName = "graftty-session"
        let sender: StubSender
        let state: WorktreeAgentStateRegistry
        let inbox: TeamInbox
        let service: IdleDeliveryService
        let frozen: Date

        init(sendResults: [Bool] = []) throws {
            self.sender = StubSender(sendResults: sendResults)
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
        let sessionName = "graftty-session"
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
