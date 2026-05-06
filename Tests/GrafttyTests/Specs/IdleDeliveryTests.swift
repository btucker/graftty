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

    @Test("@spec TEAM-IDLE-2.1: onMessageArrival with idle delivers; with active is a no-op.")
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
}
