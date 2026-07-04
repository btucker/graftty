import Foundation
import SwiftUI
import Testing
import GrafttyProtocol
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("FlowStateAppRequestDispatch")
struct FlowStateAppRequestDispatchTests {
    @Test("@spec FLOW-4.10: Flow State app request dispatch shall route context through app-built external signals where available.")
    func flowContextIncludesAppBuiltSignals() async throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activityStore = FlowStateActivityStore(rootDirectory: root)
        let worktree = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: "repo",
            repoPath: "/repo",
            worktreePath: worktree.path,
            branch: worktree.branch
        )
        let statsStore = WorktreeStatsStore(compute: { _, _, _, _ in
            WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: 3, behind: 2, insertions: 5, deletions: 1, hasUncommittedChanges: true)
            )
        })
        statsStore.refresh(worktreePath: worktree.path, repoPath: repo.path, branch: worktree.branch)
        try await waitUntil { statsStore.stats[worktree.path] != nil }

        let prStatusStore = PRStatusStore()
        prStatusStore.applyInfoForTesting(
            worktreePath: worktree.path,
            info: PRInfo(
                number: 42,
                title: "Feature",
                url: URL(string: "https://example.com/pr/42")!,
                state: .open,
                checks: .failure,
                mergeable: .conflicting,
                fetchedAt: Date(timeIntervalSince1970: 90)
            )
        )
        let flowMessageAt = Date(timeIntervalSince1970: 80)
        try activityStore.append(.init(
            createdAt: flowMessageAt,
            kind: .statusRequestSent,
            message: "asked",
            worktreeRef: worktreeRef
        ))
        try activityStore.append(.init(
            createdAt: Date(timeIntervalSince1970: 90),
            kind: .publishAccepted,
            message: "accepted recommendation",
            worktreeRef: worktreeRef
        ))
        let cooldownAt = Date(timeIntervalSince1970: 85)
        try activityStore.recordStatusRequest(worktreeRef: worktreeRef, at: cooldownAt)
        let inputRegistry = PaneInputActivityRegistry(now: { Date(timeIntervalSince1970: 70) })
        let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        inputRegistry.recordKeystroke(paneID: paneID)
        var withPane = worktree
        withPane.setAttention(
            Attention(text: "Codex needs input", timestamp: Date(timeIntervalSince1970: 75), source: .agentStop),
            pane: nil
        )
        let paneSlot = PaneSlotID(id: paneID)
        withPane.focusedPaneSlotID = paneSlot
        withPane.paneSessions[paneSlot] = PaneSessionID(id: paneID)
        let paneAppState = AppState(repos: [RepoEntry(path: repo.path, displayName: repo.displayName, worktrees: [withPane])])

        let response = FlowStateAppRequestDispatcher.handle(
            .flowContext,
            appState: paneAppState,
            store: store,
            activityStore: activityStore,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            claudeSessionRegistry: nil,
            agentStateRegistry: nil,
            inputActivityRegistry: inputRegistry,
            statusProvider: nil,
            now: { Date(timeIntervalSince1970: 100) }
        )

        if case .flowContext(let context) = response {
            let snapshot = try #require(context.worktrees.first)
            #expect(snapshot.git?.dirtyCount == 6)
            #expect(snapshot.git?.ahead == 3)
            #expect(snapshot.git?.behind == 2)
            #expect(snapshot.pr?.number == 42)
            #expect(snapshot.pr?.ciConclusion == "failure")
            #expect(snapshot.pr?.mergeState == "conflicting")
            #expect(snapshot.pr?.urgency == .critical)
            #expect(snapshot.scoring.riskUrgency == .critical)
            #expect(snapshot.agentPresence?.waiting == true)
            #expect(snapshot.lastFlowMessageAt == cooldownAt)
            #expect(snapshot.lastUserActivityAt == Date(timeIntervalSince1970: 70))
        } else {
            Issue.record("Expected flowContext response")
        }
    }

    @Test("@spec FLOW-4.11: Flow State app request dispatch shall preserve the last valid recommendation when a later publish is invalid.")
    func flowPublishPreservesValidRecommendationOnInvalidPublish() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activityStore = FlowStateActivityStore(rootDirectory: root)
        let valid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"Keep","reason":"Idle","confidence":"low"}}
        """
        let invalid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"teleport","title":"Bad","reason":"Bad","confidence":"low"}}
        """

        #expect(FlowStateAppRequestDispatcher.handle(
            .flowPublish(rawJSON: valid),
            appState: AppState(),
            store: store,
            activityStore: activityStore
        ) == .ok)

        if case .error = FlowStateAppRequestDispatcher.handle(
            .flowPublish(rawJSON: invalid),
            appState: AppState(),
            store: store,
            activityStore: activityStore
        ) {
            #expect(try store.recommendation()?.primary.title == "Keep")
        } else {
            Issue.record("Expected invalid publish error")
        }
    }

    // @spec FLOW-5.8: After accepting a valid Flow State publish, app request dispatch shall execute policy-allowed autonomous status-request actions through the team inbox.
    @Test("Valid publish executes autonomous status request action")
    func validPublishExecutesAutonomousStatusRequestAction() throws {
        UserDefaults.standard.set(FlowStatePermissionMode.conservative.rawValue, forKey: SettingsKeys.flowStatePermissionMode)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.flowStatePermissionMode) }

        let root = try temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root, idGenerator: { "flow-publish-1" }, now: { Date(timeIntervalSince1970: 100) })
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        let lead = WorktreeEntry(path: "/repo", branch: "main", state: .running)
        let feature = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [lead, feature])
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: repo.displayName,
            repoPath: repo.path,
            worktreePath: feature.path,
            branch: feature.branch
        )
        let publish = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {"intent": "none", "title": "None", "reason": "Idle", "confidence": "low"},
          "proposedActions": [{
            "id": "ask-feature",
            "kind": "team_status_request",
            "target": "\(worktreeRef)",
            "body": "\(FlowStateActionPolicy.statusRequestTemplate)",
            "requiresConfirmation": false
          }]
        }
        """
        let activityStore = FlowStateActivityStore(rootDirectory: root)

        let response = FlowStateAppRequestDispatcher.handle(
            .flowPublish(rawJSON: publish),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: root),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 100) }
        )

        #expect(response == .ok)
        let messages = try inbox.messages(teamID: repo.path)
        #expect(messages.count == 1)
        #expect(messages.first?.to.member == "feature")
        #expect(messages.first?.body == FlowStateActionPolicy.statusRequestTemplate)
        #expect(try activityStore.recent(limit: 10).contains { $0.kind == .actionExecuted })
    }

    @Test("@spec FLOW-4.12: Flow State app request dispatch shall use an injected status provider.")
    func flowStatusUsesInjectedProvider() throws {
        let response = FlowStateAppRequestDispatcher.handle(
            .flowStatus,
            appState: AppState(),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: FlowStateActivityStore(rootDirectory: try temporaryDirectory()),
            statusProvider: { FlowStatus(enabled: true, running: true, message: "Running") }
        )

        #expect(response == .flowStatus(FlowStatus(enabled: true, running: true, message: "Running")))
    }

    @Test("@spec FLOW-5.6: Flow State app request dispatch shall resolve request-status worktree refs to team members, send the fixed status request through the team inbox, and return ok for normal delivery.")
    func requestStatusResolvesWorktreeRefAndSendsTeamInboxMessage() throws {
        UserDefaults.standard.set(FlowStatePermissionMode.conservative.rawValue, forKey: SettingsKeys.flowStatePermissionMode)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.flowStatePermissionMode) }

        let root = try temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root, idGenerator: { "flow-1" }, now: { Date(timeIntervalSince1970: 100) })
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        let lead = WorktreeEntry(path: "/repo", branch: "main", state: .running)
        let feature = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [lead, feature])
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: repo.displayName,
            repoPath: repo.path,
            worktreePath: feature.path,
            branch: feature.branch
        )
        let activityStore = FlowStateActivityStore(rootDirectory: root)

        let response = FlowStateAppRequestDispatcher.handle(
            .flowRequestStatus(worktreeRef: worktreeRef, explicit: false),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 100) }
        )

        #expect(response == .ok)
        let messages = try inbox.messages(teamID: repo.path)
        #expect(messages.count == 1)
        #expect(messages.first?.from.member == "main")
        #expect(messages.first?.to.member == "feature")
        #expect(messages.first?.body == FlowStateActionPolicy.statusRequestTemplate)
        #expect(try activityStore.recent(limit: 10).contains { $0.kind == .statusRequestSent })
    }

    @Test("@spec FLOW-5.13: Flow State app request dispatch shall enforce status-request cooldowns across aliases for the same resolved worktree.")
    func requestStatusCooldownUsesResolvedWorktreeIdentityAcrossAliases() throws {
        UserDefaults.standard.set(FlowStatePermissionMode.conservative.rawValue, forKey: SettingsKeys.flowStatePermissionMode)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.flowStatePermissionMode) }

        let root = try temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root, idGenerator: { "flow-alias-1" }, now: { Date(timeIntervalSince1970: 100) })
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        let lead = WorktreeEntry(path: "/repo", branch: "main", state: .running)
        let feature = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [lead, feature])
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: repo.displayName,
            repoPath: repo.path,
            worktreePath: feature.path,
            branch: feature.branch
        )
        let activityStore = FlowStateActivityStore(rootDirectory: root)

        let first = FlowStateAppRequestDispatcher.handle(
            .flowRequestStatus(worktreeRef: worktreeRef, explicit: false),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let second = FlowStateAppRequestDispatcher.handle(
            .flowRequestStatus(worktreeRef: feature.path, explicit: false),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 101) }
        )

        #expect(first == .ok)
        #expect(second == .ok)
        #expect(try inbox.messages(teamID: repo.path).count == 1)
        #expect(try activityStore.lastStatusRequestAt(worktreeRef: worktreeRef) == Date(timeIntervalSince1970: 100))
        #expect(try activityStore.recent(limit: 10).contains { $0.kind == .statusRequestSkipped })
    }

    @Test("Flow State request dispatch uses the configured status request cooldown")
    func requestStatusCooldownUsesUserDefaultMinutes() throws {
        UserDefaults.standard.set(FlowStatePermissionMode.conservative.rawValue, forKey: SettingsKeys.flowStatePermissionMode)
        UserDefaults.standard.set(1, forKey: SettingsKeys.flowStateStatusRequestCooldownMinutes)
        defer {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.flowStatePermissionMode)
            UserDefaults.standard.removeObject(forKey: SettingsKeys.flowStateStatusRequestCooldownMinutes)
        }

        let root = try temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root, idGenerator: { UUID().uuidString }, now: { Date(timeIntervalSince1970: 100) })
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        let lead = WorktreeEntry(path: "/repo", branch: "main", state: .running)
        let feature = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [lead, feature])
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: repo.displayName,
            repoPath: repo.path,
            worktreePath: feature.path,
            branch: feature.branch
        )
        let activityStore = FlowStateActivityStore(rootDirectory: root)

        let first = FlowStateAppRequestDispatcher.handle(
            .flowRequestStatus(worktreeRef: worktreeRef, explicit: false),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let second = FlowStateAppRequestDispatcher.handle(
            .flowRequestStatus(worktreeRef: worktreeRef, explicit: false),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 161) }
        )

        #expect(first == .ok)
        #expect(second == .ok)
        #expect(try inbox.messages(teamID: repo.path).count == 2)
    }

    @Test("@spec FLOW-5.7: Flow State app request dispatch shall record no-team request-status skips as activity and return ok without throwing for normal skips.")
    func requestStatusWithoutTeamRecordsSkipAndReturnsOK() throws {
        let root = try temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main", state: .running)
        ])
        let activityStore = FlowStateActivityStore(rootDirectory: root)

        let response = FlowStateAppRequestDispatcher.handle(
            .flowRequestStatus(worktreeRef: "repo:missing", explicit: false),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 100) }
        )

        #expect(response == .ok)
        #expect(try inbox.messages(teamID: repo.path).isEmpty)
        #expect(try activityStore.recent(limit: 10).contains { $0.kind == .statusRequestSkipped })
    }

    @Test("@spec FLOW-5.11: Flow State app request dispatch shall skip status requests when the resolved team member name is ambiguous instead of delivering to the wrong worktree.")
    func requestStatusSkipsAmbiguousSanitizedMemberName() throws {
        UserDefaults.standard.set(FlowStatePermissionMode.conservative.rawValue, forKey: SettingsKeys.flowStatePermissionMode)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.flowStatePermissionMode) }

        let root = try temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root, idGenerator: { "ambiguous-flow-1" }, now: { Date(timeIntervalSince1970: 100) })
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        let lead = WorktreeEntry(path: "/repo", branch: "main", state: .running)
        let first = WorktreeEntry(path: "/repo/.worktrees/foo-bar", branch: "foo-bar", state: .running)
        let second = WorktreeEntry(path: "/repo/.worktrees/foo--bar", branch: "foo--bar", state: .running)
        #expect(WorktreeNameSanitizer.sanitize(first.branch) == WorktreeNameSanitizer.sanitize(second.branch))
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [lead, first, second])
        let secondRef = FlowWorktreeIdentity.ref(
            repoDisplayName: repo.displayName,
            repoPath: repo.path,
            worktreePath: second.path,
            branch: second.branch
        )
        let activityStore = FlowStateActivityStore(rootDirectory: root)

        let response = FlowStateAppRequestDispatcher.handle(
            .flowRequestStatus(worktreeRef: secondRef, explicit: false),
            appState: AppState(repos: [repo]),
            store: FlowStateStore(rootDirectory: try temporaryDirectory()),
            activityStore: activityStore,
            teamInbox: inbox,
            teamEventDispatcher: dispatcher,
            teamsEnabled: true,
            now: { Date(timeIntervalSince1970: 100) }
        )

        #expect(response == .ok)
        #expect(try inbox.messages(teamID: repo.path).isEmpty)
        #expect(try activityStore.recent(limit: 10).contains {
            $0.kind == .statusRequestSkipped && $0.message.contains("ambiguous")
        })
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            await Task.yield()
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-flow-state-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
