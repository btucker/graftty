import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team inbox read advancement")
struct TeamInboxReadAdvancementTests {
    @Test("Internal read advancement is scoped, validated, and idempotent")
    func exactReadAdvancementIsScopedValidatedAndIdempotent() throws {
        let fixture = try Fixture(ids: ["a-1", "b-1", "a-2"])
        let aliceFirst = try fixture.append(to: fixture.alice, body: "alice one")
        let bobMessage = try fixture.append(to: fixture.bob, body: "bob one")
        let aliceSecond = try fixture.append(to: fixture.alice, body: "alice two")
        try fixture.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: fixture.bob,
                lastDeliveredToAnySessionID: bobMessage.id
            ),
            teamID: fixture.teamID
        )

        try fixture.handler.advanceRead(
            callerWorktree: fixture.alice,
            throughID: aliceSecond.id,
            repos: [fixture.repo],
            teamsEnabled: true
        )

        #expect(try fixture.watermark(for: fixture.alice) == aliceSecond.id)
        #expect(try fixture.watermark(for: fixture.bob) == bobMessage.id)

        try fixture.handler.advanceRead(
            callerWorktree: fixture.alice,
            throughID: aliceFirst.id,
            repos: [fixture.repo],
            teamsEnabled: true
        )
        #expect(try fixture.watermark(for: fixture.alice) == aliceSecond.id)

        #expect(throws: TeamInboxError.advanceTargetNotAddressed(
            messageID: bobMessage.id,
            worktree: fixture.alice
        )) {
            try fixture.handler.advanceRead(
                callerWorktree: fixture.alice,
                throughID: bobMessage.id,
                repos: [fixture.repo],
                teamsEnabled: true
            )
        }
        #expect(throws: TeamInboxError.advanceTargetNotFound("missing")) {
            try fixture.handler.advanceRead(
                callerWorktree: fixture.alice,
                throughID: "missing",
                repos: [fixture.repo],
                teamsEnabled: true
            )
        }
    }

    @Test("A consuming CLI read exposes and acknowledges only rows deliverable to its caller identity.")
    func consumingReadCannotConsumeAnotherRuntimeTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrafttyTeamInboxManualRuntimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )
        let alice = "/repo/.worktrees/alice"
        let codex = TeamPresenceRecord(
            teamID: "/repo", worktree: alice, runtime: .codex,
            paneSessionName: "graftty-codex", pid: 101,
            processStartTimeMicroseconds: 1_001,
            registeredAt: Date(timeIntervalSince1970: 20),
            runtimeSessionID: "codex-session"
        )
        let claude = TeamPresenceRecord(
            teamID: "/repo", worktree: alice, runtime: .claude,
            paneSessionName: "graftty-claude", pid: 102,
            processStartTimeMicroseconds: 1_002,
            registeredAt: Date(timeIntervalSince1970: 10),
            runtimeSessionID: "claude-session"
        )
        var ids = ["targeted", "shared"]
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: { ids.removeFirst() }
        )
        let handler = TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: TeamEventDispatcher(
                inbox: inbox,
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: { "" }
            ),
            agentRecords: { [claude, codex] },
            agentReachability: { _ in true }
        )
        let targeted = try inbox.appendMessage(
            teamID: "/repo",
            teamName: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: alice, runtime: "codex"),
            priority: .normal,
            body: "Codex only"
        )
        let shared = try inbox.appendMessage(
            teamID: "/repo",
            teamName: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: alice, runtime: nil),
            priority: .normal,
            body: "Claude may consume"
        )
        let claudeID = TeamAgentDirectory.identity(for: claude).rawValue
        let claudePage = try handler.diagnosticPage(
            callerWorktree: alice,
            callerAgentID: claudeID,
            consuming: true,
            worktree: nil,
            repo: nil,
            member: nil,
            unread: true,
            all: false,
            beforeID: nil,
            forwardPagination: true,
            limit: 100,
            repos: [repo],
            teamsEnabled: true
        )
        #expect(claudePage.messages.map(\.id) == [shared.id])
        try handler.advanceRead(
            callerWorktree: alice,
            callerAgentID: claudeID,
            throughID: shared.id,
            repos: [repo],
            teamsEnabled: true
        )
        let skipped = try inbox.worktreeWatermark(teamID: "/repo", worktree: alice)
        #expect(skipped?.lastDeliveredToAnySessionID == shared.id)
        #expect(skipped?.pendingBeforeWatermarkIDs == [targeted.id])

        let codexID = TeamAgentDirectory.identity(for: codex).rawValue
        let codexPage = try handler.diagnosticPage(
            callerWorktree: alice,
            callerAgentID: codexID,
            consuming: true,
            worktree: nil,
            repo: nil,
            member: nil,
            unread: true,
            all: false,
            beforeID: nil,
            forwardPagination: true,
            limit: 100,
            repos: [repo],
            teamsEnabled: true
        )
        #expect(codexPage.messages.map(\.id) == [targeted.id])
        try handler.advanceRead(
            callerWorktree: alice,
            callerAgentID: codexID,
            throughID: targeted.id,
            repos: [repo],
            teamsEnabled: true
        )
        let compacted = try inbox.worktreeWatermark(teamID: "/repo", worktree: alice)
        #expect(compacted?.lastDeliveredToAnySessionID == shared.id)
        #expect(compacted?.pendingBeforeWatermarkIDs == nil)
    }

    @Test("Unread peeks use the scoped watermark without mutation")
    func unreadDiagnosticsUseTheScopedWorktreeWatermarkWithoutMutation() throws {
        let fixture = try Fixture(ids: ["a-1", "out-1", "a-2", "a-3"])
        let acknowledged = try fixture.append(to: fixture.alice, body: "old incoming")
        _ = try fixture.inbox.appendMessage(
            teamID: fixture.teamID,
            teamName: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "alice", worktree: fixture.alice, runtime: nil),
            to: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            priority: .normal,
            body: "outgoing"
        )
        let fromMain = try fixture.append(to: fixture.alice, body: "new from main")
        _ = try fixture.inbox.appendMessage(
            teamID: fixture.teamID,
            teamName: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "bob", worktree: fixture.bob, runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: fixture.alice, runtime: nil),
            priority: .normal,
            body: "new from bob"
        )
        try fixture.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: fixture.alice,
                lastDeliveredToAnySessionID: acknowledged.id
            ),
            teamID: fixture.teamID
        )
        let cursor = TeamInboxCursor(
            sessionID: "existing-session",
            worktree: fixture.alice,
            runtime: "claude",
            lastSeenID: acknowledged.id
        )
        try fixture.inbox.writeCursor(cursor, teamID: fixture.teamID)

        let page = try fixture.handler.diagnosticPage(
            callerWorktree: fixture.alice,
            worktree: nil,
            repo: nil,
            member: "main",
            unread: true,
            all: false,
            beforeID: nil,
            afterID: nil,
            snapshotThroughID: nil,
            forwardPagination: true,
            limit: 100,
            repos: [fixture.repo],
            teamsEnabled: true
        )

        #expect(page.messages == [fromMain])
        #expect(try fixture.watermark(for: fixture.alice) == acknowledged.id)
        #expect(try fixture.inbox.cursor(
            teamID: fixture.teamID,
            sessionID: cursor.sessionID
        ) == cursor)
    }

    @Test("@spec TEAM-4.10: When an unread team inbox read spans pages, the application shall return the oldest rows first from a fixed upper snapshot so only displayed rows are eligible for advancement and later arrivals remain unread.")
    func unreadPaginationUsesAnOldestFirstFixedSnapshot() throws {
        let fixture = try Fixture(ids: ["a-1", "a-2", "a-3", "a-4", "a-5", "a-6"])
        let messages = try (1...5).map { index in
            try fixture.append(to: fixture.alice, body: "alice \(index)")
        }

        let oldest = try fixture.handler.diagnosticPage(
            callerWorktree: fixture.alice,
            worktree: nil,
            repo: nil,
            member: nil,
            unread: true,
            all: true,
            beforeID: nil,
            afterID: nil,
            snapshotThroughID: nil,
            forwardPagination: true,
            limit: 2,
            repos: [fixture.repo],
            teamsEnabled: true
        )
        #expect(oldest.messages == Array(messages.prefix(2)))
        #expect(oldest.nextAfterID == messages[1].id)
        #expect(oldest.snapshotThroughID == messages[4].id)

        let appendedLater = try fixture.append(to: fixture.alice, body: "alice 6")

        let middle = try fixture.handler.diagnosticPage(
            callerWorktree: fixture.alice,
            worktree: nil,
            repo: nil,
            member: nil,
            unread: true,
            all: true,
            beforeID: nil,
            afterID: oldest.nextAfterID,
            snapshotThroughID: oldest.snapshotThroughID,
            forwardPagination: true,
            limit: 2,
            repos: [fixture.repo],
            teamsEnabled: true
        )
        #expect(middle.messages == Array(messages[2...3]))
        #expect(middle.nextAfterID == messages[3].id)
        #expect(middle.snapshotThroughID == messages[4].id)

        let newest = try fixture.handler.diagnosticPage(
            callerWorktree: fixture.alice,
            worktree: nil,
            repo: nil,
            member: nil,
            unread: true,
            all: true,
            beforeID: nil,
            afterID: middle.nextAfterID,
            snapshotThroughID: middle.snapshotThroughID,
            forwardPagination: true,
            limit: 2,
            repos: [fixture.repo],
            teamsEnabled: true
        )
        #expect(newest.messages == [messages[4]])
        #expect(newest.nextAfterID == nil)
        #expect(!newest.messages.contains(appendedLater))
    }

    @Test("Hook unread selection returns the effective floor and rows from one snapshot")
    func hookUnreadSelectionUsesTheLaterKnownAnchor() throws {
        let fixture = try Fixture(ids: ["a-1", "a-2", "a-3"])
        let cursorAnchor = try fixture.append(to: fixture.alice, body: "cursor anchor")
        let watermarkAnchor = try fixture.append(to: fixture.alice, body: "watermark anchor")
        let pending = try fixture.append(to: fixture.alice, body: "pending")
        try fixture.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: fixture.alice,
                lastDeliveredToAnySessionID: watermarkAnchor.id
            ),
            teamID: fixture.teamID
        )

        let selection = try fixture.inbox.hookUnreadMessages(
            teamID: fixture.teamID,
            recipientWorktree: fixture.alice,
            sessionLastSeenID: cursorAnchor.id
        )

        #expect(selection.readPosition == watermarkAnchor.id)
        #expect(selection.messages == [pending])
    }

    @Test("Read advancement observes the worktree watermark lock")
    func readAdvancementTimesOutUnderWatermarkLockContention() throws {
        let fixture = try Fixture(ids: ["a-1"], watermarkLockTimeout: 0.2)
        let message = try fixture.append(to: fixture.alice, body: "pending")
        let holder = try TeamTestFixtures.holdWatermarkLock(
            root: fixture.inbox.rootDirectory,
            teamID: fixture.teamID,
            worktree: fixture.alice
        )
        defer { holder.release() }

        #expect(throws: TeamInboxError.watermarkLockTimeout) {
            try fixture.handler.advanceRead(
                callerWorktree: fixture.alice,
                throughID: message.id,
                repos: [fixture.repo],
                teamsEnabled: true
            )
        }
        #expect(try fixture.watermark(for: fixture.alice) == nil)
    }

    @Test("Initial unread selection observes the worktree watermark lock")
    func unreadSnapshotTimesOutUnderWatermarkLockContention() throws {
        let fixture = try Fixture(ids: ["a-1"], watermarkLockTimeout: 0.2)
        _ = try fixture.append(to: fixture.alice, body: "pending")
        let holder = try TeamTestFixtures.holdWatermarkLock(
            root: fixture.inbox.rootDirectory,
            teamID: fixture.teamID,
            worktree: fixture.alice
        )
        defer { holder.release() }

        #expect(throws: TeamInboxError.watermarkLockTimeout) {
            try fixture.handler.diagnosticPage(
                callerWorktree: fixture.alice,
                worktree: nil,
                repo: nil,
                member: nil,
                unread: true,
                all: false,
                beforeID: nil,
                forwardPagination: true,
                limit: 100,
                repos: [fixture.repo],
                teamsEnabled: true
            )
        }
        #expect(try fixture.watermark(for: fixture.alice) == nil)
    }

    @Test("@spec TEAM-11.9: When an existing session cursor trails its worktree's shared delivery watermark, hook delivery shall use the later watermark as its effective read position so rows successfully read by another delivery surface are not redelivered.")
    func staleExistingSessionUsesTheLaterWorktreeWatermark() throws {
        let fixture = try Fixture(ids: ["a-1", "a-2", "a-3"])
        let cursorAnchor = try fixture.append(to: fixture.alice, body: "seen by this session")
        let manuallyAcknowledged = try fixture.append(to: fixture.alice, body: "manually acknowledged")
        let pending = try fixture.append(to: fixture.alice, body: "still pending")
        try fixture.inbox.writeCursor(
            TeamInboxCursor(
                sessionID: "existing-session",
                worktree: fixture.alice,
                runtime: "claude",
                lastSeenID: cursorAnchor.id
            ),
            teamID: fixture.teamID
        )
        try fixture.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: fixture.alice,
                lastDeliveredToAnySessionID: manuallyAcknowledged.id
            ),
            teamID: fixture.teamID
        )

        let output = try fixture.handler.hook(
            callerWorktree: fixture.alice,
            runtime: .claude,
            event: .sessionStart,
            sessionID: "existing-session",
            paneSessionName: nil,
            repos: [fixture.repo],
            teamsEnabled: true
        )

        #expect(!output.contains("seen by this session"))
        #expect(!output.contains("manually acknowledged"))
        #expect(output.contains("still pending"))
        #expect(try fixture.watermark(for: fixture.alice) == pending.id)
    }

    @Test("A missing session anchor keeps the conservative replay fallback")
    func missingSessionAnchorDoesNotGuessAgainstTheWatermark() throws {
        let fixture = try Fixture(ids: ["a-1", "a-2"])
        let acknowledged = try fixture.append(to: fixture.alice, body: "retained acknowledged")
        _ = try fixture.append(to: fixture.alice, body: "retained pending")
        try fixture.inbox.writeCursor(
            TeamInboxCursor(
                sessionID: "archived-session",
                worktree: fixture.alice,
                runtime: "claude",
                lastSeenID: "removed-anchor"
            ),
            teamID: fixture.teamID
        )
        try fixture.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: fixture.alice,
                lastDeliveredToAnySessionID: acknowledged.id
            ),
            teamID: fixture.teamID
        )

        let output = try fixture.handler.hook(
            callerWorktree: fixture.alice,
            runtime: .claude,
            event: .sessionStart,
            sessionID: "archived-session",
            paneSessionName: nil,
            repos: [fixture.repo],
            teamsEnabled: true
        )

        #expect(output.contains("retained acknowledged"))
        #expect(output.contains("retained pending"))
    }

    @Test("A missing worktree watermark anchor falls back to the retained session cursor")
    func missingWatermarkAnchorUsesTheSessionCursor() throws {
        let fixture = try Fixture(ids: ["a-1", "a-2"])
        let sessionAnchor = try fixture.append(to: fixture.alice, body: "seen by this session")
        let pending = try fixture.append(to: fixture.alice, body: "retained pending")
        try fixture.inbox.writeCursor(
            TeamInboxCursor(
                sessionID: "retained-session",
                worktree: fixture.alice,
                runtime: "claude",
                lastSeenID: sessionAnchor.id
            ),
            teamID: fixture.teamID
        )
        try fixture.inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: fixture.alice,
                lastDeliveredToAnySessionID: "removed-watermark"
            ),
            teamID: fixture.teamID
        )

        let output = try fixture.handler.hook(
            callerWorktree: fixture.alice,
            runtime: .claude,
            event: .sessionStart,
            sessionID: "retained-session",
            paneSessionName: nil,
            repos: [fixture.repo],
            teamsEnabled: true
        )

        #expect(!output.contains("seen by this session"))
        #expect(output.contains("retained pending"))
        #expect(try fixture.watermark(for: fixture.alice) == pending.id)
    }

    private final class Fixture {
        let teamID = "/repo"
        let alice = "/repo/.worktrees/alice"
        let bob = "/repo/.worktrees/bob"
        let repo: RepoEntry
        let inbox: TeamInbox
        let handler: TeamInboxRequestHandler

        init(ids: [String], watermarkLockTimeout: TimeInterval = 2.0) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GrafttyTeamInboxReadTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repo = TeamTestFixtures.makeRepo(
                path: "/repo",
                displayName: "repo",
                branches: ["main", "alice", "bob"]
            )
            var ids = ids
            inbox = TeamInbox(
                rootDirectory: root,
                idGenerator: {
                    guard !ids.isEmpty else { return "overflow" }
                    return ids.removeFirst()
                },
                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                watermarkLockTimeout: watermarkLockTimeout
            )
            handler = TeamInboxRequestHandler(
                inbox: inbox,
                dispatcher: TeamEventDispatcher(
                    inbox: inbox,
                    preferencesProvider: { TeamEventRoutingPreferences() },
                    templateProvider: { "" }
                )
            )
        }

        func append(to worktree: String, runtime: String? = nil, body: String) throws -> TeamInboxMessage {
            let member = worktree == alice ? "alice" : "bob"
            return try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
                to: TeamInboxEndpoint(member: member, worktree: worktree, runtime: runtime),
                priority: .normal,
                body: body
            )
        }

        func watermark(for worktree: String) throws -> String? {
            try inbox.worktreeWatermark(
                teamID: teamID,
                worktree: worktree
            )?.lastDeliveredToAnySessionID
        }
    }
}
