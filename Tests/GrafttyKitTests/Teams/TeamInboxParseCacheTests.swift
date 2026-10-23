import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec TEAM-11.11: While a team's message log is unchanged on disk, the application shall reuse its previously decoded rows instead of re-reading and re-decoding the log, so one team hook delivery decodes the log at most once.")
struct TeamInboxParseCacheTests {
    private static let alice = "/repo/.worktrees/alice"

    @Test func deliveringPostToolUseHookDecodesTheLogOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.send("urgent body", priority: .urgent)
        let before = fixture.inbox.messageLogParseCountForTesting

        let output = try fixture.hook(.postToolUse)

        #expect(output.contains("urgent body"))
        #expect(fixture.inbox.messageLogParseCountForTesting - before == 1)
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: "/repo",
            worktree: Self.alice
        )?.lastDeliveredToAnySessionID == "0001")
    }

    @Test func deliveringSessionStartHookDecodesTheLogOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.send("queued body", priority: .normal)
        let before = fixture.inbox.messageLogParseCountForTesting

        let output = try fixture.hook(.sessionStart)

        #expect(output.contains("queued body"))
        #expect(fixture.inbox.messageLogParseCountForTesting - before == 1)
    }

    @Test func idleHooksDecodeTheLogAtMostOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.send("normal body", priority: .normal)
        let before = fixture.inbox.messageLogParseCountForTesting

        _ = try fixture.hook(.preToolUse)
        #expect(fixture.inbox.messageLogParseCountForTesting - before == 0)

        let output = try fixture.hook(.postToolUse)
        #expect(!output.contains("normal body"))
        #expect(fixture.inbox.messageLogParseCountForTesting - before == 1)
    }

    @Test func nativeDeliveryReadAndAcknowledgeDecodeTheLogOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.send("native body", priority: .normal)
        let before = fixture.inbox.messageLogParseCountForTesting

        let pending = try fixture.inbox.worktreePendingMessages(
            teamID: "/repo",
            recipientWorktree: Self.alice
        )
        try fixture.inbox.acknowledgeMessages(
            teamID: "/repo",
            worktree: Self.alice,
            messageIDs: pending.map(\.id)
        )

        #expect(pending.map(\.id) == ["0001"])
        #expect(fixture.inbox.messageLogParseCountForTesting - before == 1)
    }

    @Test func appendAfterCachedReadIsVisibleToTheNextRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.send("first", priority: .normal)
        #expect(try fixture.inbox.messages(teamID: "/repo").map(\.body) == ["first"])

        try fixture.send("second", priority: .normal)

        #expect(try fixture.inbox.messages(teamID: "/repo").map(\.body) == ["first", "second"])
    }

    @Test func replacedLogIsReadAgain() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.send("first", priority: .normal)
        #expect(try fixture.inbox.messages(teamID: "/repo").count == 1)

        try FileManager.default.removeItem(
            at: TeamInbox.messagesURLFor(rootDirectory: fixture.root, teamID: "/repo")
        )
        #expect(try fixture.inbox.messagesIfFileExists(teamID: "/repo") == nil)

        try fixture.send("second", priority: .normal)
        #expect(try fixture.inbox.messages(teamID: "/repo").map(\.body) == ["second"])
    }

    private struct Fixture {
        let root: URL
        let inbox: TeamInbox
        let handler: TeamInboxRequestHandler
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-inbox-parse-cache-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var ids = ["0001", "0002", "0003"]
            let inbox = TeamInbox(
                rootDirectory: root,
                idGenerator: { ids.isEmpty ? "overflow" : ids.removeFirst() },
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            )
            self.inbox = inbox
            handler = TeamInboxRequestHandler(
                inbox: inbox,
                dispatcher: TeamEventDispatcher(
                    inbox: inbox,
                    preferencesProvider: { TeamEventRoutingPreferences() },
                    templateProvider: { "" }
                ),
                automaticDeliveryOwner: nil,
                agentRecords: { [] },
                agentReachability: { _ in false }
            )
        }

        func send(_ text: String, priority: TeamInboxPriority) throws {
            _ = try handler.send(
                callerWorktree: "/repo",
                recipient: "alice",
                text: text,
                priority: priority,
                repos: [repo]
            )
        }

        func hook(_ event: TeamHookEvent) throws -> String {
            try handler.hook(
                callerWorktree: TeamInboxParseCacheTests.alice,
                runtime: .claude,
                event: event,
                sessionID: "owner",
                paneSessionName: "graftty-owner",
                repos: [repo]
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
