import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team Inbox Request Handler")
struct TeamInboxRequestHandlerTests {
    private static func makeHandler(
        inbox: TeamInbox,
        templateProvider: @escaping () -> String = { "" },
        sessionPromptRenderer: ((TeamView, TeamMember) -> String?)? = nil
    ) -> TeamInboxRequestHandler {
        TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: TeamEventDispatcher(
                inbox: inbox,
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: templateProvider
            ),
            sessionPromptRenderer: sessionPromptRenderer
        )
    }

    @Test func sendAppendsAddressedMessage() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        )

        let delivery = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "please review",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(delivery.recipient.name == "alice")
        #expect(delivery.message.from.member == "main")
        #expect(delivery.message.to.member == "alice")
        #expect(delivery.message.body == "please review")
    }

    @Test func broadcastExcludesSenderAndDeliversToAllOthers() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice", "bob"])
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001", "0002"]), now: { Self.fixedDate })
        )

        let deliveries = try handler.broadcast(
            callerWorktree: "/repo/.worktrees/alice",
            text: "heads up",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(deliveries.map { $0.recipient.name }.sorted() == ["bob", "main"])
        #expect(deliveries.allSatisfy { $0.message.from.member == "alice" })
        // Phase 2 dispatches per-recipient so each row has a fresh ID; the
        // legacy `batchID` shared marker is no longer guaranteed.
    }

    @Test func sendRejectsUnknownRecipient() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let handler = Self.makeHandler(inbox: TeamInbox(rootDirectory: root))

        #expect(throws: TeamInboxRequestError.self) {
            try handler.send(
                callerWorktree: "/repo",
                recipient: "nobody",
                text: "hello",
                priority: .normal,
                repos: [repo],
                teamsEnabled: true
            )
        }
    }

    @Test func sessionStartIncludesRenderedConfiguredPrompt() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root),
            sessionPromptRenderer: { _, viewer in
                "Configured policy for \(viewer.name)"
            }
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .sessionStart,
            sessionID: "session-1",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(output.contains("Configured policy for alice"))
        #expect(output.contains("Graftty Agent Team session context"))
    }

    @Test func postToolUseDoesNotAdvanceCursorPastUndeliveredNormalMessage() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let ids = Self.fixedIDs(["0001", "0002"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: ids, now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "normal first",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )
        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent second",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        let postToolOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "session-1",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(postToolOutput.contains("urgent second"))
        #expect(!postToolOutput.contains("normal first"))
        let cursor = try inbox.cursor(teamID: "/repo", sessionID: "session-1")
        #expect(cursor?.lastSeenID == nil)

        let stopOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .stop,
            sessionID: "session-1",
            repos: [repo],
            teamsEnabled: true
        )
        #expect(stopOutput.contains("normal first"))
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static func fixedIDs(_ values: [String]) -> () -> String {
        var ids = values
        return {
            guard !ids.isEmpty else { return "overflow" }
            return ids.removeFirst()
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-team-inbox-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
