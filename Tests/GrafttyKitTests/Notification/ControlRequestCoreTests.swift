import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

/// The dispatcher shared by the Mac app and the headless host, driven
/// through a recording platform. Portable: runs on Linux CI.
@MainActor
@Suite("ControlRequestCore")
struct ControlRequestCoreTests {
    @MainActor
    final class RecordingRouting: ControlRemoteTeamRouting {
        var sends: [(caller: String, agent: String?, recipient: String, text: String, priority: TeamInboxPriority)] = []
        func send(callerWorktree: String, callerAgentID: String?, recipient: String,
                  text: String, priority: TeamInboxPriority) async -> ResponseMessage {
            sends.append((callerWorktree, callerAgentID, recipient, text, priority))
            return .ok
        }
    }

    @MainActor
    final class RecordingPlatform: ControlPlatform, CLIWorktreeCreationPlatform, CLIWorktreeRemovalPlatform {
        let root: URL
        var state: AppState
        let teamInbox: TeamInbox
        let teamEventDispatcher: TeamEventDispatcher
        let teamPresence: TeamPresenceStorage
        let attentionRecaps = AttentionRecapCoordinator()
        var routing: RecordingRouting? = RecordingRouting()
        var remoteTeamRouting: (any ControlRemoteTeamRouting)? { routing }
        var instructionsDirectory: URL { root }
        var stateChanges = 0
        var liveness: [(TeamHookEvent, String)] = []
        var notifications: [AgentStopNotificationContent] = []
        var platformRequests: [NotificationMessage] = []
        var controlCapabilities: Set<ControlCapability> = [.worktreeBase]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("control-core-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            teamInbox = TeamInbox(rootDirectory: root.appendingPathComponent("inbox"))
            teamEventDispatcher = TeamEventDispatcher(inbox: teamInbox, preferencesProvider: { TeamEventRoutingPreferences() },
                                                      templateProvider: { "" })
            teamPresence = TeamPresenceStorage(rootDirectory: root.appendingPathComponent("teams"))
            var worktree = WorktreeEntry(path: "/repo", branch: "main", state: .running)
            let slot = PaneSlotID()
            worktree.splitTree = SplitTree(root: .leaf(slot))
            worktree.paneSessions = [slot: PaneSessionID()]
            state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])])
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var paneSession: String { ZmxLauncher.sessionName(for: state.repos[0].worktrees[0].paneSessions.values.first!) }

        func stateDidChange() throws { stateChanges += 1 }
        func providerActivity(path: String, paneSessionName: String?, sessionID: String?,
                              activity: ProviderSleepActivity, runtime: TeamHookRuntime) {}
        func recordHookLiveness(runtime: TeamHookRuntime, event: TeamHookEvent, sessionID: String?,
                                paneSessionName: String, attentionReason: AgentHookAttentionReason?) {
            liveness.append((event, paneSessionName))
        }
        func instructionsDefaultBranch(repoPath: String, hint: String?) -> String? { hint }
        func paneTitle(for slot: PaneSlotID, in worktree: WorktreeEntry) -> String? { "editor" }
        func postAgentNotification(_ content: AgentStopNotificationContent, worktreePath: String) {
            notifications.append(content)
        }
        func hookDeliveryPolicy(presence: [TeamPresenceRecord]) -> TeamHookDeliveryPolicy { TeamHookDeliveryPolicy() }
        let worktreeCreations = CLIWorktreeCreationStore()
        let worktreeRemovals = CLIWorktreeRemovalStore()
        var worktreeCreation: any CLIWorktreeCreationPlatform { self }
        var worktreeRemoval: any CLIWorktreeRemovalPlatform { self }
        var agentPromptDirectory: URL { root }
        func saveStateNow() throws {}
        func finishWorktreeCreation(_ plan: CLIWorktreeCreationPlan) async -> String? { nil }
        func wakeWorktree(_ path: String) -> Bool { true }
        func removeWorktree(_ path: String, force: Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError> {
            .success(WorktreeRemovalOutcome(dismissed: false))
        }
        func handlePlatformRequest(_ message: NotificationMessage) async -> ResponseMessage? {
            platformRequests.append(message)
            return .ok
        }
    }

    @Test("@spec AGENT-3.30: When the app receives an Attention recap, it shall persist the brief immediately while reserving stopped attention and its notification for the actual Stop hook.")
    func recapPublishesBeforeCompletion() async throws {
        let platform = try RecordingPlatform()
        let recap = AttentionRecap(title: "Immediate report", completed: "Published", next: "Review", need: "Approve?", emoji: "🔇")
        #expect(await ControlRequestCore.handleRequest(.attentionReport(callerWorktree: "/repo", callerAgentID: "codex-a", recap: recap), platform: platform) == .ok)
        #expect(platform.state.worktree(forPath: "/repo")?.brief?.completed == "Published")
        #expect(platform.state.worktree(forPath: "/repo")?.emoji == "🔇")
        #expect(platform.state.worktree(forPath: "/repo")?.unseenAgentStop == nil)
        #expect(platform.notifications.isEmpty)
        #expect(platform.stateChanges == 1)
        _ = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo", callerAgentID: "codex-a", runtime: .codex, event: .postToolUse, sessionID: "s", paneSessionName: nil), platform: platform)
        let result = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo", callerAgentID: "codex-a", runtime: .codex, event: .stop, sessionID: "s", paneSessionName: nil, turnID: "turn"), platform: platform)
        #expect(result == .teamHookOutput("{}"))
        #expect(platform.state.worktree(forPath: "/repo")?.unseenAgentStop?.recap?.need == "Approve?")
        #expect(platform.notifications.count == 1)
    }

    @Test("Completing an earlier report preserves a newer brief and does not repeat its history entry")
    func completionDoesNotRepublishOldBrief() async throws {
        let platform = try RecordingPlatform()
        let first = AttentionRecap(title: "Reports", completed: "First", next: "Review", need: "Approve first?",
            emoji: "🔇", historyEntry: .init(headline: "First report"))
        let second = AttentionRecap(title: "Reports", completed: "Second", next: "Review", emoji: "🔇",
            historyEntry: .init(headline: "Second report"))
        _ = await ControlRequestCore.handleRequest(.attentionReport(callerWorktree: "/repo", callerAgentID: "codex-a", recap: first), platform: platform)
        _ = await ControlRequestCore.handleRequest(.attentionReport(callerWorktree: "/repo", callerAgentID: "codex-b", recap: second), platform: platform)
        _ = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo", callerAgentID: "codex-a", runtime: .codex, event: .stop, sessionID: "s", paneSessionName: nil, turnID: "turn"), platform: platform)
        #expect(platform.state.worktree(forPath: "/repo")?.brief?.completed == "Second")
        #expect(platform.state.worktree(forPath: "/repo")?.brief?.history.map(\.title) == ["First report", "Second report"])
        #expect(platform.state.worktree(forPath: "/repo")?.unseenAgentStop?.recap?.need == "Approve first?")
    }

    @Test("Socket Stop fallback carries a file-published report without a correction or stale reuse")
    func socketFallbackVerifiesFileReport() async throws {
        let platform = try RecordingPlatform()
        let handoff = AttentionFileHandoff(rootDirectory: platform.root.appendingPathComponent("handoff"))
        let recap = AttentionRecap(title: "Fallback", completed: "Published", next: "Review", need: "Approve?", emoji: "🔇")
        try handoff.publish(recap, worktree: "/repo", agentID: "codex-a")
        let report = try #require(handoff.publishedReport(worktree: "/repo", agentID: "codex-a"))
        let request = NotificationMessage.teamHook(callerWorktree: "/repo", callerAgentID: "codex-a", runtime: .codex, event: .stop, sessionID: "s", paneSessionName: nil, turnID: "first", fallbackReport: report)
        let roundTripped = try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(request))
        #expect(await ControlRequestCore.handleRequest(roundTripped, platform: platform) == .teamHookOutput("{}"))
        #expect(platform.state.worktree(forPath: "/repo")?.unseenAgentStop?.recap?.need == "Approve?")
        #expect(platform.notifications.count == 1)
        #expect(await ControlRequestCore.handleRequest(roundTripped, platform: platform) == .teamHookOutput("{}"))
        #expect(platform.notifications.count == 1)
        let next = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo", callerAgentID: "codex-a", runtime: .codex, event: .stop, sessionID: "s", paneSessionName: nil, turnID: "second", fallbackReport: report), platform: platform)
        #expect(next == .teamHookOutput(TeamHookRenderer.requestRecap()))
    }

    @Test("fire-and-forget messages apply only on the message path and answer nil on the request path")
    func fireAndForgetSplit() async throws {
        let platform = try RecordingPlatform()
        #expect(await ControlRequestCore.handleRequest(.notify(path: "/repo", text: "hi"), platform: platform) == nil)
        #expect(platform.state.worktree(forPath: "/repo")?.attention == nil)
        #expect(ControlRequestCore.handleMessage(.notify(path: "/repo", text: "hi"), platform: platform))
        #expect(platform.state.worktree(forPath: "/repo")?.attention?.text == "hi")
        #expect(platform.stateChanges == 1)
        #expect(!ControlRequestCore.handleMessage(.listPanes(path: "/repo"), platform: platform))
    }

    @Test("notify auto-clear removes only the attention it set")
    func notifyAutoClear() async throws {
        let platform = try RecordingPlatform()
        ControlRequestCore.handleMessage(.notify(path: "/repo", text: "soon", clearAfter: 0.05), platform: platform)
        #expect(platform.state.worktree(forPath: "/repo")?.attention?.clearAfter == 0.05)
        for _ in 0..<100 where platform.state.worktree(forPath: "/repo")?.attention != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(platform.state.worktree(forPath: "/repo")?.attention == nil)

        ControlRequestCore.handleMessage(.notify(path: "/repo", text: "old", clearAfter: 0.05), platform: platform)
        ControlRequestCore.handleMessage(.notify(path: "/repo", text: "new"), platform: platform)
        try await Task.sleep(for: .milliseconds(200))
        #expect(platform.state.worktree(forPath: "/repo")?.attention?.text == "new")
    }

    @MainActor
    final class ManualTimer {
        var now = ContinuousClock.now
        var deadlines: [ContinuousClock.Instant] = []
    }

    @Test("notify auto-clear fixes its deadline when the notify arrives, so a busy main actor cannot postpone it")
    func notifyAutoClearDeadlineIsFixedAtArrival() async throws {
        let platform = try RecordingPlatform()
        let timer = ManualTimer()
        let arrival = timer.now
        ControlRequestCore.handleMessage(.notify(path: "/repo", text: "soon", clearAfter: 1), platform: platform,
                                         now: { timer.now }, sleepUntil: { timer.deadlines.append($0) })
        // The main actor stays busy for five seconds before the timer task runs.
        timer.now = arrival + .seconds(5)
        for _ in 0..<1000 where platform.state.worktree(forPath: "/repo")?.attention != nil { await Task.yield() }
        #expect(timer.deadlines == [arrival + .seconds(1)])
        #expect(platform.state.worktree(forPath: "/repo")?.attention == nil)
    }

    @Test("requests the core does not own reach the platform unchanged")
    func platformRequestsForwarded() async throws {
        let platform = try RecordingPlatform()
        for message: NotificationMessage in [.listPanes(path: "/repo"), .closePane(path: "/repo", index: 1),
                                             .reconnectRemoteClient(target: "mac")] {
            #expect(await ControlRequestCore.handleRequest(message, platform: platform) == .ok)
        }
        #expect(platform.platformRequests == [.listPanes(path: "/repo"), .closePane(path: "/repo", index: 1),
                                              .reconnectRemoteClient(target: "mac")])
        _ = await ControlRequestCore.handleRequest(.teamList(callerWorktree: "/repo"), platform: platform)
        #expect(platform.platformRequests.count == 3)
    }

    @Test("graftty-mac sends forward through remote routing after caller checks")
    func remoteForwarding() async throws {
        let platform = try RecordingPlatform()
        let address = "graftty-mac://device/Users/peer/api"
        #expect(await ControlRequestCore.handleRequest(.teamSend(callerWorktree: "/repo", callerAgentID: "codex-a",
            recipient: address, text: "hello", priority: .urgent), platform: platform) == .ok)
        #expect(await ControlRequestCore.handleRequest(.teamSend(callerWorktree: "/repo", recipient: address,
            text: "hi", priority: .normal), platform: platform) == .ok)
        let routing = try #require(platform.routing)
        #expect(routing.sends.map(\.text) == ["hello", "hi"])
        #expect(routing.sends.map(\.agent) == ["codex-a", nil])
        #expect(routing.sends.map(\.priority) == [.urgent, .normal])

        #expect(await ControlRequestCore.handleRequest(.teamSend(callerWorktree: "/untracked", recipient: address,
            text: "x", priority: .normal), platform: platform) == .error(TeamInboxRequestError.callerNotTracked.description))
        #expect(routing.sends.count == 2)
        platform.routing = nil
        #expect(await ControlRequestCore.handleRequest(.teamSend(callerWorktree: "/repo", recipient: address,
            text: "x", priority: .normal), platform: platform) == .error("remote team connection is unavailable"))
        #expect(routing.sends.count == 2)
    }

    @Test("team hooks record liveness only for panes tracked in the caller's worktree and post stopped-turn notifications")
    func teamHookPlatformEffects() async throws {
        let platform = try RecordingPlatform()
        let pane = platform.paneSession
        _ = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo", runtime: .codex, event: .preToolUse,
            sessionID: "s", paneSessionName: pane), platform: platform)
        _ = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/elsewhere", runtime: .codex, event: .preToolUse,
            sessionID: "s", paneSessionName: pane), platform: platform)
        #expect(platform.liveness.map(\.0) == [.preToolUse])

        _ = await ControlRequestCore.handleRequest(.teamHook(callerWorktree: "/repo", callerAgentID: "codex-a",
            runtime: .codex, event: .stop, sessionID: "s", paneSessionName: pane, stopHookActive: true),
            platform: platform)
        let stop = try #require(platform.state.worktree(forPath: "/repo")?.lastAgentStop)
        #expect(stop.agentName == "Codex")
        #expect(stop.paneTitle == "editor")
        #expect(platform.notifications.count == 1)
    }
}
