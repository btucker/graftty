import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamInbox")
struct TeamInboxTests {
    @Test func appendPointToPointMessageRoundTrips() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "m").next,
            now: { Date(timeIntervalSince1970: 1_800) }
        )

        let message = try inbox.appendMessage(
            teamID: "acme",
            teamName: "acme-web",
            repoPath: "/repo/acme",
            from: TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: "codex"),
            to: TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: nil),
            priority: .normal,
            body: "please review"
        )

        let stored = try inbox.messages(teamID: "acme")
        #expect(stored == [message])
        #expect(message.id == "m0001")
        #expect(message.batchID == nil)
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_800))
        #expect(message.to.member == "main")
        #expect(message.body == "please review")
    }

    @Test func broadcastWritesOneMessagePerRecipientWithSharedBatchID() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "b").next,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let messages = try inbox.appendBroadcast(
            teamID: "acme",
            teamName: "acme-web",
            repoPath: "/repo/acme",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude"),
            recipients: [
                TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: nil),
                TeamInboxEndpoint(member: "feature-ui", worktree: "/repo/acme/.worktrees/feature-ui", runtime: nil),
            ],
            priority: .urgent,
            body: "pause pushes"
        )

        #expect(messages.count == 2)
        #expect(Set(messages.map(\.batchID)) == ["b0001"])
        #expect(messages.map(\.id) == ["b0002", "b0003"])
        #expect(Set(messages.map(\.to.member)) == ["feature-auth", "feature-ui"])
        #expect(try inbox.messages(teamID: "acme") == messages)
    }

    @Test func unreadFiltersByRecipientPriorityAndCursor() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "u").next,
            now: { Date(timeIntervalSince1970: 3_000) }
        )
        let sender = TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude")
        let feature = TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: nil)
        let other = TeamInboxEndpoint(member: "feature-ui", worktree: "/repo/acme/.worktrees/feature-ui", runtime: nil)

        let first = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "normal one")
        _ = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: other, priority: .urgent, body: "not yours")
        let urgent = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .urgent, body: "urgent one")

        let unread = try inbox.unreadMessages(
            teamID: "acme",
            recipientWorktree: feature.worktree,
            after: first.id,
            priorities: [.urgent]
        )

        #expect(unread == [urgent])
    }

    @Test func unreadCursorFollowsAppendOrderForArbitraryIDs() throws {
        let ids = FixedIDGenerator(["z-later-sort", "a-earlier-sort"])
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: ids.next,
            now: { Date(timeIntervalSince1970: 3_100) }
        )
        let sender = TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude")
        let feature = TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: nil)

        let first = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "first")
        let second = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "second")

        let unread = try inbox.unreadMessages(
            teamID: "acme",
            recipientWorktree: feature.worktree,
            after: first.id
        )

        #expect(unread == [second])
    }

    @Test func cursorAndWorktreeWatermarkRoundTrip() throws {
        let inbox = TeamInbox(rootDirectory: try temporaryDirectory())
        let cursor = TeamInboxCursor(
            sessionID: "codex:feature-auth:1",
            worktree: "/repo/acme/.worktrees/feature-auth",
            runtime: "codex",
            lastSeenID: "m123"
        )

        try inbox.writeCursor(cursor, teamID: "acme")
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: "/repo/acme/.worktrees/feature-auth",
                lastDeliveredToAnySessionID: "m120"
            ),
            teamID: "acme"
        )

        #expect(try inbox.cursor(teamID: "acme", sessionID: cursor.sessionID) == cursor)
        #expect(
            try inbox.worktreeWatermark(
                teamID: "acme",
                worktree: "/repo/acme/.worktrees/feature-auth"
            )?.lastDeliveredToAnySessionID == "m120"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrafttyTeamInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class IncrementingIDGenerator {
    private let prefix: String
    private var nextNumber = 1

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> String {
        defer { nextNumber += 1 }
        return "\(prefix)\(String(format: "%04d", nextNumber))"
    }
}

private final class FixedIDGenerator {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        guard !values.isEmpty else { return "overflow" }
        return values.removeFirst()
    }
}
