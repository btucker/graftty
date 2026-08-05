import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit
import GrafttyProtocol

@Suite("GrafttyApp — Codex app-server inbox delivery wiring")
struct CodexAppServerInboxDeliveryWiringTests {
    @Test("New inbox messages trigger exactly one Codex app-server delivery per recipient worktree, regardless of concurrent fan-out order.")
    func newMessagesTriggerDeliveryPerRecipientWorktree() async {
        let delivery = RecordingCodexDelivery()
        let state = GrafttyApp.CodexAppServerInboxObserverDeliveryState(lastSeenCount: 1)
        let messages = [
            Self.message(id: "old", worktree: "/repo/.worktrees/alice"),
            Self.message(id: "new-1", worktree: "/repo/.worktrees/alice"),
            Self.message(id: "new-2", worktree: "/repo/.worktrees/bob"),
            Self.message(id: "new-3", worktree: "/repo/.worktrees/alice"),
        ]

        let recipientWorktrees = await state.claimRecipientWorktrees(in: messages)
        await GrafttyApp.deliverCodexAppServerMessages(
            teamID: "/repo",
            recipientWorktrees: recipientWorktrees,
            delivery: delivery
        )

        let calls = await delivery.calls
        #expect(calls.count == 2)
        #expect(Set(calls) == Set([
            .init(team: "/repo", worktree: "/repo/.worktrees/alice"),
            .init(team: "/repo", worktree: "/repo/.worktrees/bob"),
        ]))
    }

    @Test("Production observer state treats its initial full inbox snapshot as already seen.")
    func initialObserverSnapshotIsMarkedSeenWithoutDelivery() async {
        let state = GrafttyApp.CodexAppServerInboxObserverDeliveryState(skipInitialSnapshot: true)
        let initialMessages = [
            Self.message(id: "old-1", worktree: "/repo/.worktrees/alice"),
            Self.message(id: "old-2", worktree: "/repo/.worktrees/bob"),
        ]

        let initialWorktrees = await state.claimRecipientWorktrees(in: initialMessages)
        let appendedWorktrees = await state.claimRecipientWorktrees(in: initialMessages + [
            Self.message(id: "new-1", worktree: "/repo/.worktrees/alice"),
        ])

        #expect(initialWorktrees.isEmpty)
        #expect(appendedWorktrees == ["/repo/.worktrees/alice"])
    }

    @Test("Rapid successive observer callbacks do not redeliver already claimed messages while delivery is suspended.")
    func rapidCallbacksClaimMessageRangesBeforeAwaitingDelivery() async {
        let delivery = BlockingCodexDelivery(blockFirstCall: true)
        let state = GrafttyApp.CodexAppServerInboxObserverDeliveryState()
        let firstMessages = [
            Self.message(id: "new-1", worktree: "/repo/.worktrees/alice"),
        ]
        let secondMessages = [
            Self.message(id: "new-1", worktree: "/repo/.worktrees/alice"),
            Self.message(id: "new-2", worktree: "/repo/.worktrees/bob"),
        ]

        async let first: Void = Self.claimAndDeliver(
            state: state,
            teamID: "/repo",
            messages: firstMessages,
            delivery: delivery
        )
        let firstStarted = await Self.waitUntil { await delivery.callCount() >= 1 }

        async let second: Void = Self.claimAndDeliver(
            state: state,
            teamID: "/repo",
            messages: secondMessages,
            delivery: delivery
        )
        let secondStarted = await Self.waitUntil { await delivery.callCount() >= 2 }

        await delivery.unblockAll()
        await first
        await second

        #expect(firstStarted)
        #expect(secondStarted)
        #expect(await delivery.calls == [
            .init(team: "/repo", worktree: "/repo/.worktrees/alice"),
            .init(team: "/repo", worktree: "/repo/.worktrees/bob"),
        ])
    }

    @Test("A slow delivery for one worktree does not block another worktree in the same batch from starting.")
    func batchDeliveryFansOutAcrossRecipientWorktrees() async {
        let delivery = BlockingCodexDelivery(blockWorktree: "/repo/.worktrees/alice")

        async let batch: Void = GrafttyApp.deliverCodexAppServerMessages(
            teamID: "/repo",
            recipientWorktrees: ["/repo/.worktrees/alice", "/repo/.worktrees/bob"],
            delivery: delivery
        )

        let bothStarted = await Self.waitUntil { await delivery.callCount() >= 2 }
        await delivery.unblockAll()
        await batch

        #expect(bothStarted)
        #expect(await delivery.callSet() == Set([
            .init(team: "/repo", worktree: "/repo/.worktrees/alice"),
            .init(team: "/repo", worktree: "/repo/.worktrees/bob"),
        ]))
    }

    @MainActor
    @Test("""
    @spec TEAM-12.1: When a direct `team send` message arrives for a live Codex agent whose running worktree is in the background with no mounted terminal surface, the application shall wake and deliver to the agent without selecting or foregrounding that worktree.
    """)
    func directMessageDeliversToBackgroundAgentWithoutMountedSurface() async throws {
        let fixture = try BackgroundDeliveryFixture()
        #expect(fixture.terminalManager.handle(forSessionName: fixture.sessionName) == nil)

        _ = try fixture.dispatcher.dispatchTeamMessage(
            fromWorktree: fixture.repo.path,
            to: "alice",
            text: "direct background message",
            priority: .normal,
            repos: [fixture.repo],
            teamsEnabled: true
        )
        await fixture.deliverAppendedMessages()

        #expect(await fixture.delivery.calls == [
            .init(team: fixture.teamID, worktree: fixture.backgroundWorktree),
        ])
    }

    @MainActor
    @Test("""
    @spec TEAM-12.2: When an automated team lifecycle or state event arrives for a live Codex agent whose running worktree is in the background with no mounted terminal surface, the application shall wake and deliver to the agent without selecting or foregrounding that worktree.
    """)
    func automatedEventDeliversToBackgroundAgentWithoutMountedSurface() async throws {
        let fixture = try BackgroundDeliveryFixture()
        #expect(fixture.terminalManager.handle(forSessionName: fixture.sessionName) == nil)
        let event = ChannelServerMessage.event(
            type: TeamChannelEvents.WireType.prStateChanged,
            attrs: [
                "worktree": fixture.backgroundWorktree,
                "to": "open",
                "from": "draft",
                "pr_number": "42",
                "pr_url": "https://example.test/pr/42",
                "provider": "github",
                "repo": "example/repo",
            ],
            body: "PR #42 state changed: draft → open"
        )

        try fixture.dispatcher.dispatchRoutableEvent(
            event,
            subjectWorktreePath: fixture.backgroundWorktree,
            repos: [fixture.repo]
        )
        await fixture.deliverAppendedMessages()

        #expect(await fixture.delivery.calls == [
            .init(team: fixture.teamID, worktree: fixture.backgroundWorktree),
        ])
    }

    @MainActor
    @Test("""
    @spec TEAM-12.3: On application launch, the immediate retry of preexisting unread messages shall refresh automatic-delivery liveness after restoring pane-session metadata, so a live background Codex agent is not delayed until the periodic presence retry.
    """)
    func startupRetryUsesRestoredBackgroundPaneMetadata() async throws {
        let teamID = "/repo"
        let worktree = "/repo/.worktrees/alice"
        let paneSlot = PaneSlotID()
        let paneSession = PaneSessionID()
        let sessionName = ZmxLauncher.sessionName(for: paneSession)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-startup-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let terminalManager = TerminalManager(
            socketPath: root.appendingPathComponent("graftty.sock").path
        )
        let presence = TeamPresenceRecord(
            teamID: teamID,
            worktree: worktree,
            runtime: .codex,
            paneSessionName: sessionName,
            pid: 123,
            processStartTimeMicroseconds: 456,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let inbox = TeamInbox(rootDirectory: root)
        _ = try Self.appendMessage(to: worktree, inbox: inbox)

        #expect(GrafttyApp.livePaneSessionNamesForAutomaticDelivery(
            records: [presence],
            terminalManager: terminalManager
        ).isEmpty)

        // Mirrors restoreRunningWorktrees installing pane metadata before
        // startup refreshes liveness and schedules its immediate retry.
        terminalManager.recordPaneSession(
            paneSession,
            for: paneSlot,
            worktreePath: worktree
        )
        let restoredSessionNames = GrafttyApp.livePaneSessionNamesForAutomaticDelivery(
            records: [presence],
            terminalManager: terminalManager
        )
        let delivery = OwnerGatedRecordingDelivery(
            presence: presence,
            liveSessionNames: restoredSessionNames
        )

        await GrafttyApp.retryCodexAppServerDeliveryForPresenceWorktrees(
            inbox: inbox,
            records: [presence],
            delivery: delivery
        )

        #expect(terminalManager.handle(forSessionName: sessionName) == nil)
        #expect(await delivery.calls == [
            .init(team: teamID, worktree: worktree),
        ])
    }

    @Test("Presence refresh skips Codex worktrees with no pending unread messages.")
    func presenceRefreshSkipsWhenNoPendingUnreadMessages() async throws {
        let delivery = RecordingCodexDelivery()
        let inbox = try Self.makeInbox()
        let delivered = try Self.appendMessage(to: "/repo/.worktrees/alice", inbox: inbox)
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: "/repo/.worktrees/alice",
                lastDeliveredToAnySessionID: delivered.id
            ),
            teamID: "/repo"
        )
        let records = [
            Self.presence(team: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex, pane: "graftty-a"),
        ]

        await GrafttyApp.retryCodexAppServerDeliveryForPresenceWorktrees(
            inbox: inbox,
            records: records,
            delivery: delivery
        )

        #expect(await delivery.calls.isEmpty)
    }

    @Test("Presence refresh retries only Codex worktrees with pending unread messages.")
    func presenceRefreshRetriesOnlyPendingCodexPresenceWorktrees() async throws {
        let delivery = RecordingCodexDelivery()
        let inbox = try Self.makeInbox()
        let bobDelivered = try Self.appendMessage(to: "/repo/.worktrees/bob", inbox: inbox)
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: "/repo/.worktrees/bob",
                lastDeliveredToAnySessionID: bobDelivered.id
            ),
            teamID: "/repo"
        )
        _ = try Self.appendMessage(to: "/repo/.worktrees/alice", inbox: inbox)
        _ = try Self.appendMessage(to: "/other/.worktrees/dan", teamID: "/other", inbox: inbox)
        let records = [
            Self.presence(team: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex, pane: "graftty-a"),
            Self.presence(team: "/repo", worktree: "/repo/.worktrees/alice", runtime: .codex, pane: "graftty-a2"),
            Self.presence(team: "/repo", worktree: "/repo/.worktrees/bob", runtime: .codex, pane: "graftty-b"),
            Self.presence(team: "/repo", worktree: "/repo/.worktrees/claude", runtime: .claude, pane: "graftty-c"),
            Self.presence(team: "/other", worktree: "/other/.worktrees/dan", runtime: .codex, pane: "graftty-d"),
        ]

        await GrafttyApp.retryCodexAppServerDeliveryForPresenceWorktrees(
            inbox: inbox,
            records: records,
            delivery: delivery
        )

        #expect(await delivery.callSet() == Set([
            .init(team: "/repo", worktree: "/repo/.worktrees/alice"),
            .init(team: "/other", worktree: "/other/.worktrees/dan"),
        ]))
    }

    @Test("Presence refresh waits for another runtime to consume the head message.")
    func presenceRefreshRespectsRuntimeTargetedHeadOfLine() async throws {
        let delivery = RecordingCodexDelivery()
        let inbox = try Self.makeInbox()
        let worktree = "/repo/.worktrees/alice"
        let claudeMessage = try Self.appendMessage(
            to: worktree,
            runtime: TeamHookRuntime.claude.rawValue,
            inbox: inbox
        )
        _ = try Self.appendMessage(to: worktree, inbox: inbox)
        let records = [
            Self.presence(
                team: "/repo",
                worktree: worktree,
                runtime: .codex,
                pane: "graftty-a"
            ),
        ]

        await GrafttyApp.retryCodexAppServerDeliveryForPresenceWorktrees(
            inbox: inbox,
            records: records,
            delivery: delivery
        )
        #expect(await delivery.calls.isEmpty)

        #expect(try inbox.compareAndAdvanceWorktreeWatermark(
            teamID: "/repo",
            worktree: worktree,
            to: claudeMessage.id
        ))
        await GrafttyApp.retryCodexAppServerDeliveryForPresenceWorktrees(
            inbox: inbox,
            records: records,
            delivery: delivery
        )
        #expect(await delivery.calls == [
            .init(team: "/repo", worktree: worktree),
        ])
    }

    private static func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    private static func claimAndDeliver(
        state: GrafttyApp.CodexAppServerInboxObserverDeliveryState,
        teamID: String,
        messages: [TeamInboxMessage],
        delivery: CodexAppServerDeliveryTrigger
    ) async {
        let recipientWorktrees = await state.claimRecipientWorktrees(in: messages)
        await GrafttyApp.deliverCodexAppServerMessages(
            teamID: teamID,
            recipientWorktrees: recipientWorktrees,
            delivery: delivery
        )
    }

    private static func message(id: String, worktree: String) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id,
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            team: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "member", worktree: worktree, runtime: "codex"),
            priority: .normal,
            body: "hello"
        )
    }

    private static func makeInbox() throws -> TeamInbox {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-presence-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var nextID = 0
        return TeamInbox(
            rootDirectory: dir,
            idGenerator: {
                nextID += 1
                return "generated-\(nextID)"
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    @discardableResult
    private static func appendMessage(
        to worktree: String,
        teamID: String = "/repo",
        runtime: String? = "codex",
        inbox: TeamInbox
    ) throws -> TeamInboxMessage {
        return try inbox.appendMessage(
            teamID: teamID,
            teamName: teamID == "/repo" ? "repo" : "other",
            repoPath: teamID,
            from: TeamInboxEndpoint(member: "main", worktree: teamID, runtime: nil),
            to: TeamInboxEndpoint(member: "member", worktree: worktree, runtime: runtime),
            priority: .normal,
            body: "hello"
        )
    }

    private static func presence(
        team: String,
        worktree: String,
        runtime: TeamHookRuntime,
        pane: String
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: team,
            worktree: worktree,
            runtime: runtime,
            paneSessionName: pane,
            pid: 123,
            processStartTimeMicroseconds: 456,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    actor RecordingCodexDelivery: CodexAppServerDeliveryTrigger {
        struct Call: Equatable, Hashable {
            let team: String
            let worktree: String
        }

        private var recordedCalls: [Call] = []

        var calls: [Call] {
            recordedCalls
        }

        func callCount() -> Int {
            recordedCalls.count
        }

        func callSet() -> Set<Call> {
            Set(recordedCalls)
        }

        func onMessageArrival(team: String, worktree: String) async {
            recordedCalls.append(.init(team: team, worktree: worktree))
        }
    }

    actor BlockingCodexDelivery: CodexAppServerDeliveryTrigger {
        typealias Call = RecordingCodexDelivery.Call

        private var recordedCalls: [Call] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseCount = 0
        private let blockFirstCall: Bool
        private let blockWorktree: String?

        init(blockFirstCall: Bool = false, blockWorktree: String? = nil) {
            self.blockFirstCall = blockFirstCall
            self.blockWorktree = blockWorktree
        }

        var calls: [Call] {
            recordedCalls
        }

        func callCount() -> Int {
            recordedCalls.count
        }

        func callSet() -> Set<Call> {
            Set(recordedCalls)
        }

        func onMessageArrival(team: String, worktree: String) async {
            let callNumber = recordedCalls.count + 1
            recordedCalls.append(.init(team: team, worktree: worktree))
            if (blockFirstCall && callNumber == 1) || blockWorktree == worktree {
                await waitForRelease()
            }
        }

        func unblock() {
            if releaseWaiters.isEmpty {
                releaseCount += 1
            } else {
                releaseWaiters.removeFirst().resume()
            }
        }

        func unblockAll() {
            if releaseWaiters.isEmpty {
                releaseCount += 1
                return
            }
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func waitForRelease() async {
            if releaseCount > 0 {
                releaseCount -= 1
                return
            }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

    }

    @MainActor
    struct BackgroundDeliveryFixture {
        let teamID = "/repo"
        let backgroundWorktree = "/repo/.worktrees/alice"
        let sessionName: String
        let repo: RepoEntry
        let inbox: TeamInbox
        let dispatcher: TeamEventDispatcher
        let terminalManager: TerminalManager
        let observerState = GrafttyApp.CodexAppServerInboxObserverDeliveryState()
        let delivery: OwnerGatedRecordingDelivery

        init() throws {
            let paneSlot = PaneSlotID()
            let paneSession = PaneSessionID()
            self.sessionName = ZmxLauncher.sessionName(for: paneSession)
            self.repo = RepoEntry(
                path: teamID,
                displayName: "repo",
                worktrees: [
                    WorktreeEntry(path: teamID, branch: "main", state: .running),
                    WorktreeEntry(path: backgroundWorktree, branch: "alice", state: .running),
                ]
            )

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-background-delivery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.inbox = TeamInbox(rootDirectory: root)
            self.dispatcher = TeamEventDispatcher(
                inbox: inbox,
                preferencesProvider: {
                    TeamEventRoutingPreferences(
                        prStateChanged: [.worktree],
                        prMerged: [.root],
                        ciConclusionChanged: [.worktree],
                        mergabilityChanged: [.worktree]
                    )
                },
                templateProvider: { "" }
            )

            let terminalManager = TerminalManager(
                socketPath: root.appendingPathComponent("graftty.sock").path
            )
            terminalManager.recordPaneSession(
                paneSession,
                for: paneSlot,
                worktreePath: backgroundWorktree
            )
            self.terminalManager = terminalManager

            let presence = TeamPresenceRecord(
                teamID: teamID,
                worktree: backgroundWorktree,
                runtime: .codex,
                paneSessionName: sessionName,
                pid: 123,
                processStartTimeMicroseconds: 456,
                registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let liveSessionNames = GrafttyApp.livePaneSessionNamesForAutomaticDelivery(
                records: [presence],
                terminalManager: terminalManager
            )
            self.delivery = OwnerGatedRecordingDelivery(
                presence: presence,
                liveSessionNames: liveSessionNames
            )
        }

        func deliverAppendedMessages() async {
            let messages = (try? inbox.messages(teamID: teamID)) ?? []
            let recipientWorktrees = await observerState.claimRecipientWorktrees(in: messages)
            await GrafttyApp.deliverCodexAppServerMessages(
                teamID: teamID,
                recipientWorktrees: recipientWorktrees,
                delivery: delivery
            )
        }
    }

    actor OwnerGatedRecordingDelivery: CodexAppServerDeliveryTrigger {
        typealias Call = RecordingCodexDelivery.Call

        private let presence: TeamPresenceRecord
        private let liveSessionNames: Set<String>
        private var recordedCalls: [Call] = []

        init(
            presence: TeamPresenceRecord,
            liveSessionNames: Set<String>
        ) {
            self.presence = presence
            self.liveSessionNames = liveSessionNames
        }

        var calls: [Call] {
            recordedCalls
        }

        func onMessageArrival(team: String, worktree: String) async {
            let resolver = TeamDeliveryOwnershipResolver(
                records: { [presence] in [presence] },
                liveness: BackgroundDeliveryLiveness(
                    liveSessionNames: liveSessionNames,
                    processStartTimeMicroseconds: presence.processStartTimeMicroseconds
                )
            )
            let owner = resolver.owner(for: TeamDeliveryOwnerKey(
                teamID: team,
                worktree: worktree,
                runtime: .codex
            ))
            guard owner != nil else { return }
            recordedCalls.append(.init(team: team, worktree: worktree))
        }
    }

    struct BackgroundDeliveryLiveness: TeamDeliveryLivenessChecking {
        let liveSessionNames: Set<String>
        let processStartTimeMicroseconds: Int64?

        func isLivePaneSession(_ sessionName: String) -> Bool {
            liveSessionNames.contains(sessionName)
        }

        func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
            processStartTimeMicroseconds
        }
    }
}
