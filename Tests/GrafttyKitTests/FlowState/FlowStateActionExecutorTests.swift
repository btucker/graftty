import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateActionExecutor")
struct FlowStateActionExecutorTests {
    @Test("@spec FLOW-5.3: Flow State shall autonomously execute only policy-allowed team status requests and shall record skipped or confirmation-required actions as activity.")
    func executesOnlyAutonomousStatusRequest() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger()
        let executor = FlowStateActionExecutor(
            activityStore: activity,
            teamMessenger: sender,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let allowed = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "feature",
            body: FlowStateActionPolicy.statusRequestTemplate,
            requiresConfirmation: false
        )
        let focus = FlowProposedAction(
            id: "focus",
            kind: .focusWorktree,
            target: "repo:feature",
            body: nil,
            requiresConfirmation: false
        )

        try executor.executeAutonomousActions([allowed, focus])

        #expect(sender.sentStatusRequests.count == 1)
        #expect(sender.sentStatusRequests.first?.target == "feature")
        #expect(try activity.recent(limit: 10).contains { $0.kind == .actionRequiresConfirmation })
    }

    @Test("@spec FLOW-5.4: When Flow State permission mode is Manual Only, the application shall not execute autonomous status requests and shall record them as requiring confirmation.")
    func manualOnlyPermissionModeDisablesAutonomousStatusRequests() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger()
        let executor = FlowStateActionExecutor(
            activityStore: activity,
            teamMessenger: sender,
            permissionMode: .manualOnly,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let allowed = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "feature",
            body: FlowStateActionPolicy.statusRequestTemplate,
            requiresConfirmation: false
        )

        try executor.executeAutonomousActions([allowed])

        #expect(sender.sentStatusRequests.isEmpty)
        #expect(try activity.recent(limit: 10).contains { $0.kind == .actionRequiresConfirmation })
    }

    @Test("@spec FLOW-5.5: `graftty flow request-status` shall construct the fixed status-request body internally, enforce cooldowns for autonomous requests, and record normal skips without throwing.")
    func requestStatusUsesFixedTemplateAndCooldown() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger()
        let now = Date(timeIntervalSince1970: 100)
        let executor = FlowStateActionExecutor(
            activityStore: activity,
            teamMessenger: sender,
            now: { now }
        )

        try executor.requestStatus(worktreeRef: "repo:feature", explicit: false)
        try executor.requestStatus(worktreeRef: "repo:feature", explicit: false)

        #expect(sender.sentStatusRequests.map(\.body) == [FlowStateActionPolicy.statusRequestTemplate])
        #expect(try activity.recent(limit: 10).contains { $0.kind == .statusRequestSkipped })
    }
}

private final class RecordingFlowTeamMessenger: FlowTeamMessaging {
    struct Sent: Equatable {
        var target: String
        var body: String
    }

    var sentStatusRequests: [Sent] = []
    var sentMessages: [Sent] = []

    func sendStatusRequest(target: String, body: String) throws {
        sentStatusRequests.append(Sent(target: target, body: body))
    }

    func sendMessage(target: String, body: String) throws {
        sentMessages.append(Sent(target: target, body: body))
    }
}
