import Foundation
import Testing
@testable import GrafttyKit

@Suite("Idle delivery end-to-end — Stop hook → state → zmx-send")
struct IdleDeliveryEndToEndTests {
    @Test("Stop hook + idle state + pending message → zmx writer receives formatted text and submit:true.")
    func stopFiresZmxSend() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inbox = TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { Date() })
        let state = WorktreeAgentStateRegistry()
        let writer = StubWriter()
        let service = IdleDeliveryService(
            inbox: inbox, state: state, nudgeSender: ZmxNudgeSender(writer: writer)
        )
        let pane = UUID()
        let worktree = "/repo/.worktrees/alice"
        let team = "/repo"

        _ = try inbox.appendMessage(
            teamID: team, teamName: "repo", repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: worktree, runtime: nil),
            priority: .normal, kind: "team_message", body: "hello"
        )

        state.handleSessionStart(worktree: worktree, runtime: "codex")
        state.handleStop(worktree: worktree, runtime: "codex", lastInputAt: nil)
        await service.onStop(team: team, worktree: worktree, runtime: "codex", paneID: pane)

        #expect(writer.writes.count == 1)
        #expect(writer.writes[0].submit == true)
        #expect(writer.writes[0].sessionName == ZmxLauncher.sessionName(for: pane))
    }

    final class StubWriter: ZmxWriter, @unchecked Sendable {
        struct W { let sessionName: String; let text: String; let submit: Bool }
        var writes: [W] = []
        func write(sessionName: String, text: String, submit: Bool) async throws {
            writes.append(.init(sessionName: sessionName, text: text, submit: submit))
        }
    }
}
