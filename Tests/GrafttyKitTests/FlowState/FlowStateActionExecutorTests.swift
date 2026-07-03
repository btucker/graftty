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

    @Test("@spec FLOW-5.12: Manual Only mode shall not block a Flow State status-request action after explicit UI confirmation.")
    func confirmedStatusRequestBypassesManualOnlyMode() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger()
        let executor = FlowStateActionExecutor(
            activityStore: activity,
            teamMessenger: sender,
            permissionMode: .manualOnly,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let confirmed = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "repo:feature",
            body: FlowStateActionPolicy.statusRequestTemplate,
            requiresConfirmation: true
        )

        try executor.executeConfirmedAction(confirmed)

        #expect(sender.sentStatusRequests.map(\.target) == ["repo:feature"])
        #expect(try activity.recent(limit: 10).contains { $0.kind == .statusRequestSent })
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

    @Test("@spec FLOW-5.10: Flow State status-request cooldowns shall use canonical worktree identity rather than the caller's raw target alias.")
    func requestStatusCooldownUsesCanonicalTarget() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger(canonicalTargets: [
            "repo:feature": "repo#abcd1234:feature",
            "/repo/.worktrees/feature": "repo#abcd1234:feature"
        ])
        let executor = FlowStateActionExecutor(
            activityStore: activity,
            teamMessenger: sender,
            now: { Date(timeIntervalSince1970: 100) }
        )

        try executor.requestStatus(worktreeRef: "repo:feature", explicit: false)
        try executor.requestStatus(worktreeRef: "/repo/.worktrees/feature", explicit: false)

        #expect(sender.sentStatusRequests.map(\.target) == ["repo#abcd1234:feature"])
        #expect(try activity.lastStatusRequestAt(worktreeRef: "repo#abcd1234:feature") == Date(timeIntervalSince1970: 100))
        #expect(try activity.recent(limit: 10).contains { $0.kind == .statusRequestSkipped })
    }

    @Test("@spec FLOW-5.9: Publish-time autonomous Flow State status-request actions shall obey the same per-worktree cooldown as direct request-status calls.")
    func autonomousStatusRequestActionsUseCooldown() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger()
        let executor = FlowStateActionExecutor(
            activityStore: activity,
            teamMessenger: sender,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let action = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "repo:feature",
            body: FlowStateActionPolicy.statusRequestTemplate,
            requiresConfirmation: false
        )

        try executor.executeAutonomousActions([action])
        try executor.executeAutonomousActions([action])

        #expect(sender.sentStatusRequests.count == 1)
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
    var canonicalTargets: [String: String]

    init(canonicalTargets: [String: String] = [:]) {
        self.canonicalTargets = canonicalTargets
    }

    func sendStatusRequest(target: String, body: String) throws {
        sentStatusRequests.append(Sent(target: target, body: body))
    }

    func sendMessage(target: String, body: String) throws {
        sentMessages.append(Sent(target: target, body: body))
    }

    func canonicalStatusRequestTarget(_ target: String) -> String? {
        canonicalTargets[target] ?? target
    }
}
