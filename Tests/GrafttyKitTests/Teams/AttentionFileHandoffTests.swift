import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("Attention file handoff")
struct AttentionFileHandoffTests {
    @Test("@spec AGENT-3.13: When a sandboxed agent reports a recap and then stops, the application shall consume one durable stopped-turn file containing that recap without requiring control-socket access.")
    func stagedRecapBecomesOneStoppedTurn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let recap = AttentionRecap(title: "Posting eval", context: "Testing a smaller extraction model.",
                                   completed: "Ran the holdout.", next: "Review the results.")

        try handoff.stage(recap, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "thread-1", paneSessionName: "pane-1", stopHookActive: false
        ) == .queued)

        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.count == 1)
        #expect(events.first?.recap == recap)
        #expect(events.first?.worktree == "/repo/one")
        #expect(events.first?.agentID == "codex-1")
        #expect(events.first?.paneSessionName == "pane-1")
        #expect(try handoff.consumeStops { events.append($0) } == 0)
    }

    @Test("@spec AGENT-3.14: When a sandboxed agent stops without a recap, the Stop hook shall request one recap once and then queue a generic stopped card if the continued turn still has none.")
    func stopRequestsOnceThenQueuesGenericCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)

        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: nil, paneSessionName: nil, stopHookActive: false
        ) == .requestRecap)
        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: nil, paneSessionName: nil, stopHookActive: true
        ) == .queued)

        var events: [AttentionFileStopEvent] = []
        #expect(try handoff.consumeStops { events.append($0) } == 1)
        #expect(events.first?.recap == nil)
    }

    @Test("@spec AGENT-3.15: When stopped-turn files exist before or arrive after the Attention watcher starts, the application shall process both through directory events with a periodic scan as backup.")
    func observerReplaysAndDetectsNewStops() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-observer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let observed = DispatchSemaphore(value: 0)
        let observer = AttentionFileHandoffObserver(handoff: handoff)
        defer { observer.stop() }

        _ = try handoff.stop(worktree: "/repo/one", agentID: nil, runtime: .codex,
                             sessionID: nil, paneSessionName: nil, stopHookActive: false)
        try observer.start {
            _ = try? handoff.consumeStops { _ in observed.signal() }
        }
        #expect(observed.wait(timeout: .now() + 5) == .success)

        _ = try handoff.stop(worktree: "/repo/two", agentID: nil, runtime: .claude,
                             sessionID: nil, paneSessionName: nil, stopHookActive: false)
        #expect(observed.wait(timeout: .now() + 5) == .success)
    }

    @Test("@spec AGENT-3.16: When duplicate Stop hooks run for the same Codex turn, the application shall queue one stopped card and shall not request another recap after the first hook consumes it.")
    func duplicateStopForTurnDoesNotRequestAgain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-attention-duplicate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = AttentionFileHandoff(rootDirectory: root)
        let recap = AttentionRecap(title: "Posting eval", completed: "Ran holdout.", next: "Review results.")
        try handoff.stage(recap, worktree: "/repo/one", agentID: "codex-1")

        for _ in 0..<2 {
            #expect(try handoff.stop(
                worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
                sessionID: "session-1", paneSessionName: nil,
                stopHookActive: false, turnID: "turn-1"
            ) == .queued)
        }
        #expect(try handoff.consumeStops { _ in } == 1)

        try handoff.stage(recap, worktree: "/repo/one", agentID: "codex-1")
        #expect(try handoff.stop(
            worktree: "/repo/one", agentID: "codex-1", runtime: .codex,
            sessionID: "session-1", paneSessionName: nil,
            stopHookActive: false, turnID: "turn-2"
        ) == .queued)
        #expect(try handoff.consumeStops { _ in } == 1)
    }
}
