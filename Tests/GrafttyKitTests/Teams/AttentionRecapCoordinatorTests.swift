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
        need: nil
    )

    @Test("@spec AGENT-3.9: When an agent reports a recap between stopped turns, the application shall show that recap on its next stopped turn and consume it once without requesting another turn.")
    func reportedRecapIsConsumedOnce() {
        let coordinator = AttentionRecapCoordinator()
        coordinator.report(recap, worktree: "/repo/one", agentID: "codex-1")
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: false) == .record(recap))
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: true) == .record(nil))
    }

    @Test("@spec AGENT-3.10: When an agent stops without reporting a recap, the application shall request one continuation once, then show a generic stopped card if the continued turn still has no report.")
    func missingRecapRequestsOnce() {
        let coordinator = AttentionRecapCoordinator()
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: false) == .requestRecap)
        #expect(coordinator.stop(worktree: "/repo/one", agentID: "codex-1", stopHookActive: true) == .record(nil))
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
