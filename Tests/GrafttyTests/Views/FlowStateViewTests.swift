import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("FlowStateViewModel")
struct FlowStateViewTests {
    @Test("@spec FLOW-7.1: The Flow State sidebar row shall render a calm status label from the latest recommendation instead of counting every attention event.")
    func sidebarStatusUsesPrimaryIntent() {
        let rec = FlowRecommendationEnvelope(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1),
            primary: FlowPrimaryRecommendation(
                worktreeRef: "repo:feature",
                intent: .stay,
                title: "Stay here",
                reason: "Because",
                confidence: .medium
            )
        )

        #expect(FlowStateSidebarStatus.label(
            recommendation: rec,
            status: FlowStatus(enabled: true, running: true, message: nil)
        ) == "Stay here")
    }

    @Test("@spec FLOW-7.2: When Flow State has no valid recommendation, the view model shall render setup or unavailable state instead of a fake next action.")
    func unavailableDoesNotInventAction() {
        let model = FlowStateViewModel.make(
            recommendation: nil,
            status: FlowStatus(enabled: false, running: false, message: "Needs setup")
        )

        #expect(model.primaryTitle == "Needs setup")
        #expect(model.primaryReason.contains("Enable Flow State"))
    }

    @Test("@spec FLOW-7.3: Flow State shall render recent activity such as publish errors and skipped status requests separately from the primary recommendation.")
    func activityDoesNotBecomePrimaryRecommendation() {
        let activity = [
            FlowStateActivity(createdAt: Date(timeIntervalSince1970: 1), kind: .publishError, message: "invalid enum", worktreeRef: nil),
            FlowStateActivity(createdAt: Date(timeIntervalSince1970: 2), kind: .statusRequestSkipped, message: "cooldown", worktreeRef: "repo:feature")
        ]

        let model = FlowStateViewModel.make(
            recommendation: nil,
            status: FlowStatus(enabled: true, running: true, message: nil),
            activity: activity
        )

        #expect(model.primaryTitle != "invalid enum")
        #expect(model.recentActivity.map(\.message).contains("invalid enum"))
        #expect(model.recentActivity.map(\.message).contains("cooldown"))
    }

    @Test("Proposed actions expose policy-derived presentation state.")
    func actionRowsUseEffectivePolicy() {
        let actions = [
            FlowProposedAction(
                id: "auto",
                kind: .teamStatusRequest,
                target: "repo:feature",
                body: FlowStateActionPolicy.statusRequestTemplate,
                requiresConfirmation: true
            ),
            FlowProposedAction(
                id: "confirm",
                kind: .focusWorktree,
                target: "repo:feature",
                requiresConfirmation: false
            ),
            FlowProposedAction(
                id: "manual",
                kind: .paneCommand,
                target: "repo:feature",
                body: "git status"
            )
        ]
        let recommendation = FlowRecommendationEnvelope(
            generatedAt: Date(timeIntervalSince1970: 1),
            primary: FlowPrimaryRecommendation(intent: .stay, title: "Stay", reason: "Because", confidence: .medium),
            proposedActions: actions
        )

        let model = FlowStateViewModel.make(
            recommendation: recommendation,
            status: FlowStatus(enabled: true, running: true)
        )

        #expect(model.proposedActions.map(\.state) == [.autonomous, .needsConfirmation, .explicitOptInOnly])
        #expect(model.proposedActions.map(\.isConfirmable) == [false, true, false])
    }
}
