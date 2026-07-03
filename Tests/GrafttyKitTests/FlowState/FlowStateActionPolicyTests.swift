import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateActionPolicy")
struct FlowStateActionPolicyTests {
    @Test("@spec FLOW-4.1: Flow State shall treat an agent-provided `requiresConfirmation` value as advisory and derive the effective confirmation requirement from Graftty policy.")
    func confirmationIsDerivedByPolicy() {
        let action = FlowProposedAction(
            id: "focus",
            kind: .focusWorktree,
            target: "repo:feature",
            body: nil,
            requiresConfirmation: false
        )
        #expect(FlowStateActionPolicy.effectiveRequirement(for: action) == .confirmationRequired)
    }

    @Test("@spec FLOW-4.2: Flow State may execute autonomous team status requests only when they are fixed-shape, single-target status-gathering template messages.")
    func autonomousStatusRequestRequiresTemplateShape() {
        let ok = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "feature",
            body: "[Flow State] Please reply with status, blocker, next action, tests/PR state, and whether you need the human.",
            requiresConfirmation: false
        )
        let missingHumanNeed = FlowProposedAction(
            id: "missing-human",
            kind: .teamStatusRequest,
            target: "feature",
            body: "[Flow State] Please reply with status, blocker, next action, and tests/PR state.",
            requiresConfirmation: false
        )
        let mutation = FlowProposedAction(
            id: "mutate",
            kind: .teamStatusRequest,
            target: "feature",
            body: "[Flow State] Please reply with status, blocker, next action, whether you need the human, then run tests and push fixes.",
            requiresConfirmation: false
        )

        #expect(FlowStateActionPolicy.effectiveRequirement(for: ok) == .autonomousAllowed)
        #expect(FlowStateActionPolicy.effectiveRequirement(for: missingHumanNeed) == .confirmationRequired)
        #expect(FlowStateActionPolicy.effectiveRequirement(for: mutation) == .confirmationRequired)
    }

    @Test("@spec FLOW-4.6: Flow State shall require confirmation for team messages, focus changes, and agent restarts, and shall require explicit opt-in for pane commands.")
    func nonStatusActionsAreNotAutonomous() {
        let actions: [(FlowProposedAction, FlowActionRequirement)] = [
            (
                FlowProposedAction(id: "msg", kind: .teamMessage, target: "feature", body: "Please check in."),
                .confirmationRequired
            ),
            (
                FlowProposedAction(id: "focus", kind: .focusWorktree, target: "repo:feature"),
                .confirmationRequired
            ),
            (
                FlowProposedAction(id: "restart", kind: .restartAgent, target: "repo:feature"),
                .confirmationRequired
            ),
            (
                FlowProposedAction(id: "cmd", kind: .paneCommand, target: "repo:feature", body: "make test"),
                .explicitOptInOnly
            )
        ]

        for (action, expected) in actions {
            #expect(FlowStateActionPolicy.effectiveRequirement(for: action) == expected)
        }
    }
}
