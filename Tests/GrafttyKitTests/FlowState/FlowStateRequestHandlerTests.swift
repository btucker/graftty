import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateRequestHandler")
struct FlowStateRequestHandlerTests {
    @Test("@spec FLOW-4.4: Flow State request handling shall persist notes, summaries, snoozes, and recommendations and return typed status/context/recommendation responses.")
    func handlerPersistsAndReturnsFlowState() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activity = FlowStateActivityStore(rootDirectory: root)
        let handler = FlowStateRequestHandler(
            store: store,
            activityStore: activity,
            appState: AppState(repos: [
                RepoEntry(path: "/repo", displayName: "repo", worktrees: [
                    WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
                ])
            ]),
            status: FlowStatus(enabled: true, running: false, message: "Needs start"),
            now: { Date(timeIntervalSince1970: 100) }
        )

        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: "repo",
            repoPath: "/repo",
            worktreePath: "/repo/.worktrees/feature",
            branch: "feature"
        )
        let summary = FlowWorktreeSummary(
            worktreeRef: worktreeRef,
            updatedAt: Date(timeIntervalSince1970: 100),
            summary: "Blocked",
            nextAction: "Answer",
            needsHuman: true
        )
        #expect(try handler.handle(.flowSummary(summary)) == .ok)
        #expect(try handler.handle(.flowNote(worktreeRef: worktreeRef, body: "Prefer narrow scope.")) == .ok)
        #expect(try handler.handle(.flowSnooze(worktreeRef: worktreeRef, until: .nextFocusBreak, reason: "after break")) == .ok)
        #expect(try handler.handle(.flowStatus) == .flowStatus(FlowStatus(enabled: true, running: false, message: "Needs start")))

        let contextResponse = try handler.handle(.flowContext)
        let context = try #require(contextResponse)
        if case .flowContext(let envelope) = context {
            let snapshot = try #require(envelope.worktrees.first)
            #expect(snapshot.summary?.summary == "Blocked")
            #expect(snapshot.note?.body == "Prefer narrow scope.")
            #expect(snapshot.snooze?.until == .nextFocusBreak)
        } else {
            Issue.record("Expected flowContext response")
        }
    }

    @Test("@spec FLOW-4.5: If `flow publish` receives invalid structured output, the application shall keep the last valid recommendation and record a Flow State activity error.")
    func invalidPublishKeepsLastValidRecommendationAndRecordsActivity() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activity = FlowStateActivityStore(rootDirectory: root)
        let handler = FlowStateRequestHandler(
            store: store,
            activityStore: activity,
            appState: AppState(),
            now: { Date(timeIntervalSince1970: 100) }
        )
        let valid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"}}
        """
        #expect(try handler.handle(.flowPublish(rawJSON: valid)) == .ok)

        let invalid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"teleport","title":"Bad","reason":"Bad","confidence":"low"}}
        """
        if case .error = try handler.handle(.flowPublish(rawJSON: invalid)) {
            #expect(try store.recommendation()?.primary.title == "None")
            #expect(try activity.recent(limit: 1).first?.kind == .publishError)
        } else {
            Issue.record("Expected invalid publish error")
        }
    }

    @Test("@spec FLOW-4.8: If no stored recommendation exists, Flow State recommend shall return a low-confidence none recommendation.")
    func recommendReturnsLowConfidenceNoneWhenAbsent() throws {
        let handler = FlowStateRequestHandler(
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: FlowStateActivityStore(rootDirectory: try temporaryDirectory()),
            appState: AppState(),
            now: { Date(timeIntervalSince1970: 100) }
        )

        let recommendResponse = try handler.handle(.flowRecommend)
        let response = try #require(recommendResponse)
        if case .flowRecommendation(let recommendation) = response {
            #expect(recommendation.primary.intent == .none)
            #expect(recommendation.primary.confidence == .low)
        } else {
            Issue.record("Expected recommendation response")
        }
    }

    @Test("@spec FLOW-4.9: Flow State request handling shall leave request-status execution to the Task 5 action executor.")
    func requestStatusReturnsNil() throws {
        let handler = FlowStateRequestHandler(
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: FlowStateActivityStore(rootDirectory: try temporaryDirectory()),
            appState: AppState()
        )

        #expect(try handler.handle(.flowRequestStatus(worktreeRef: "repo:feature", explicit: false)) == nil)
    }
}
