import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateRefreshCoordinator")
struct FlowStateRefreshCoordinatorTests {
    @Test("@spec FLOW-5.1: Flow State shall request a recommendation refresh on view open, selected-worktree stability, attention events after a stable focus block, and a conservative background interval.")
    func refreshTriggersFollowPolicy() {
        let now = Date(timeIntervalSince1970: 1_000)
        var coordinator = FlowStateRefreshCoordinator(
            refreshInterval: 600,
            focusStabilityDelay: 30,
            attentionStableFocusDelay: 300,
            statusRequestCooldown: 1_200,
            now: { now }
        )

        #expect(coordinator.shouldRefresh(for: .viewOpened) == true)
        coordinator.recordSelectionChanged(to: "repo:feature", at: now)
        #expect(coordinator.shouldRefresh(for: .selectionStable(
            worktreeRef: "repo:feature",
            selectedAt: now.addingTimeInterval(-31)
        )) == true)
        #expect(coordinator.shouldRefresh(for: .attention(
            worktreeRef: "repo:other",
            currentFocusStableSince: now.addingTimeInterval(-301)
        )) == true)
        coordinator.recordBackgroundRefresh(at: now)
        #expect(coordinator.shouldRefresh(for: .backgroundTick) == false)
        #expect(coordinator.shouldRefresh(for: .backgroundTick, at: now.addingTimeInterval(601)) == true)
    }

    @Test("@spec FLOW-5.2: Flow State shall not ask the same worktree agent for status more than once during the configured cooldown unless the user explicitly requests refresh.")
    func statusRequestCooldownIsEnforced() {
        let now = Date(timeIntervalSince1970: 1_000)
        var coordinator = FlowStateRefreshCoordinator(statusRequestCooldown: 1_200, now: { now })

        coordinator.recordStatusRequest(worktreeRef: "repo:feature", at: now)

        #expect(coordinator.canRequestStatus(
            worktreeRef: "repo:feature",
            explicit: false,
            at: now.addingTimeInterval(100)
        ) == false)
        #expect(coordinator.canRequestStatus(
            worktreeRef: "repo:feature",
            explicit: true,
            at: now.addingTimeInterval(100)
        ) == true)
        #expect(coordinator.canRequestStatus(
            worktreeRef: "repo:feature",
            explicit: false,
            at: now.addingTimeInterval(1_201)
        ) == true)
    }
}
