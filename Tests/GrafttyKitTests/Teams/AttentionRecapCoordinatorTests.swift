import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@MainActor
@Suite("Agent attention recaps")
struct AttentionRecapCoordinatorTests {
    private let recap = AttentionRecap(
        title: "Posting detail model evals",
        completed: "v3 scored 0.910 against a700's 0.935.",
        next: "Run four evals on the new holdout, prod200, and us1000.",
        need: nil, emoji: "🧪"
    )

    @Test("An older file receipt cannot replace a newer pending socket report")
    func pendingReportTimeIsMonotonic() {
        let coordinator = AttentionRecapCoordinator()
        var old = recap
        old.completed = "Old"
        coordinator.report(recap, worktree: "/repo", agentID: "agent", reportedAt: Date(timeIntervalSince1970: 200))
        #expect(!coordinator.report(old, worktree: "/repo", agentID: "agent", reportedAt: Date(timeIntervalSince1970: 100)))
        #expect(coordinator.stop(worktree: "/repo", agentID: "agent", stopHookActive: false, turnID: "turn") == .record(recap))
    }

    @Test("A distinct native peer turn cannot reuse a completed socket report without UserPromptSubmit")
    func peerTurnDoesNotReuseCompletedReport() {
        let coordinator = AttentionRecapCoordinator()
        coordinator.report(recap, worktree: "/repo", agentID: "agent")
        #expect(coordinator.stop(worktree: "/repo", agentID: "agent", stopHookActive: false, turnID: "first") == .record(recap))
        #expect(coordinator.stop(worktree: "/repo", agentID: "agent", stopHookActive: false, turnID: "second") == .requestRecap)
    }

    @Test("Socket recap without emoji is preserved without a correction turn")
    func legacyRecapStopsQuietly() {
        let coordinator = AttentionRecapCoordinator()
        var legacy = recap
        legacy.emoji = nil
        coordinator.report(legacy, worktree: "/repo/one", agentID: "codex-1")
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: false) == .record(legacy))
    }

    @Test("@spec AGENT-3.9: When an agent reports a recap with a task-specific emoji, the application shall retain it for the current turn and attach it to completion attention once without requesting another turn.")
    func reportedRecapCompletesOnce() {
        let coordinator = AttentionRecapCoordinator()
        coordinator.report(recap, worktree: "/repo/one", agentID: "codex-1")
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: false) == .record(recap))
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: true) == .alreadyRecorded)
    }

    @Test("@spec AGENT-3.10: When an agent stops without reporting a recap, the application shall request a recap as a fallback and allow completion if that correction turn also fails.")
    func missingRecapRequestsOneFallback() {
        let coordinator = AttentionRecapCoordinator()
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: false) == .requestRecap)
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: true) == .record(nil))
    }

    @Test("Starting a new turn discards only that agent's pending socket recap")
    func newTurnDoesNotReuseEarlierReport() {
        let coordinator = AttentionRecapCoordinator()
        coordinator.report(recap, worktree: "/repo/one", agentID: "codex-1")
        coordinator.report(recap, worktree: "/repo/one", agentID: "codex-2")
        coordinator.beginTurn(worktree: "/repo/one", agentID: "codex-1")
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: false) == .requestRecap)
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-2", stopHookActive: false) == .record(recap))
    }

    @Test("@spec AGENT-3.11: While several agents share a worktree, the application shall accept only a recap from the agent whose stopped turn is being handled.")
    func recapDoesNotCrossAgentsOrWorktrees() {
        let coordinator = AttentionRecapCoordinator()
        coordinator.report(recap, worktree: "/repo/one", agentID: "codex-1")
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-2", stopHookActive: true) == .record(nil))
        #expect(coordinator.stop(worktree: "/repo/two", agentID: "codex-1", stopHookActive: true) == .record(nil))
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: false) == .record(recap))
    }
}
