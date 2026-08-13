import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamInbox")
struct TeamInboxTests {
    @Test("Agent-targeted rows are deliverable only to the exact runtime agent.")
    func agentTargetedDeliveryIsExact() {
        let message = TeamInboxMessage(
            id: "1",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            team: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(
                member: "alice",
                worktree: "/repo/alice",
                runtime: "codex",
                agentID: "codex-111111111111"
            ),
            priority: .normal,
            body: "hello"
        )

        #expect(TeamInbox.isDeliverable(
            message,
            toRuntime: "codex",
            agentID: "codex-111111111111"
        ))
        #expect(!TeamInbox.isDeliverable(
            message,
            toRuntime: "codex",
            agentID: "codex-222222222222"
        ))
        #expect(!TeamInbox.isDeliverable(message, toRuntime: "claude", agentID: nil))
    }
    @Test("A watcher claiming with its agent identity consumes rows pinned to that agent; an identity-less claim leaves them for native delivery.")
    func claimHonorsAgentPinnedRows() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "m").next,
            now: { Date(timeIntervalSince1970: 1_800) }
        )
        let worktree = "/repo/alice"
        let agentID = "claude-111111111111"
        try inbox.writeCursor(
            TeamInboxCursor(
                sessionID: "s1",
                worktree: worktree,
                runtime: "claude",
                lastSeenID: nil
            ),
            teamID: "/repo"
        )
        _ = try inbox.appendMessage(
            teamID: "/repo",
            teamName: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(
                member: "alice",
                worktree: worktree,
                runtime: "claude",
                agentID: agentID
            ),
            priority: .normal,
            body: "pinned"
        )

        #expect(try inbox.claimNextUnreadMessage(
            teamID: "/repo",
            sessionID: "s1",
            recipientWorktree: worktree,
            runtime: "claude"
        ) == nil)
        let claimed = try inbox.claimNextUnreadMessage(
            teamID: "/repo",
            sessionID: "s1",
            recipientWorktree: worktree,
            runtime: "claude",
            agentID: agentID
        )
        #expect(claimed?.body == "pinned")
    }

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
                lastDeliveredToAnySessionID: "m120",
                pendingBeforeWatermarkIDs: ["m122"]
            ),
            teamID: "acme"
        )

        #expect(try inbox.cursor(teamID: "acme", sessionID: cursor.sessionID) == cursor)
        #expect(
            try inbox.worktreeWatermark(
                teamID: "acme",
                worktree: "/repo/acme/.worktrees/feature-auth"
            ) == TeamInboxWorktreeWatermark(
                worktree: "/repo/acme/.worktrees/feature-auth",
                lastDeliveredToAnySessionID: "m120",
                pendingBeforeWatermarkIDs: ["m122"]
            )
        )
    }

    @Test("Pending gaps stay bounded to unresolved rows while the delivery watermark advances.")
    func pendingGapsDoNotAccumulateDeliveredRows() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "m").next
        )
        let sender = TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil)
        let recipient = TeamInboxEndpoint(
            member: "feature",
            worktree: "/repo/.worktrees/feature",
            runtime: nil
        )
        let reserved = try inbox.appendMessage(
            teamID: "repo",
            teamName: "repo",
            repoPath: "/repo",
            from: sender,
            to: TeamInboxEndpoint(
                member: recipient.member,
                worktree: recipient.worktree,
                runtime: "codex"
            ),
            priority: .normal,
            body: "reserved"
        )
        let second = try inbox.appendMessage(
            teamID: "repo", teamName: "repo", repoPath: "/repo",
            from: sender, to: recipient, priority: .normal, body: "second"
        )
        let third = try inbox.appendMessage(
            teamID: "repo", teamName: "repo", repoPath: "/repo",
            from: sender, to: recipient, priority: .normal, body: "third"
        )

        try inbox.acknowledgeMessages(
            teamID: "repo",
            worktree: recipient.worktree,
            messageIDs: [second.id]
        )
        try inbox.acknowledgeMessages(
            teamID: "repo",
            worktree: recipient.worktree,
            messageIDs: [third.id]
        )

        let skipped = try inbox.worktreeWatermark(
            teamID: "repo",
            worktree: recipient.worktree
        )
        #expect(skipped?.lastDeliveredToAnySessionID == third.id)
        #expect(skipped?.pendingBeforeWatermarkIDs == [reserved.id])
        #expect(try inbox.worktreePendingMessages(
            teamID: "repo",
            recipientWorktree: recipient.worktree
        ).map(\.id) == [reserved.id])

        try inbox.acknowledgeMessages(
            teamID: "repo",
            worktree: recipient.worktree,
            messageIDs: [reserved.id]
        )
        let compacted = try inbox.worktreeWatermark(
            teamID: "repo",
            worktree: recipient.worktree
        )
        #expect(compacted?.lastDeliveredToAnySessionID == third.id)
        #expect(compacted?.pendingBeforeWatermarkIDs == nil)
    }

    @Test func compareAndAdvanceWorktreeWatermarkRefusesToRegress() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "m").next,
            now: { Date(timeIntervalSince1970: 4_000) }
        )
        let sender = TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude")
        let feature = TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: nil)

        let older = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "older")
        let newer = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "newer")
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(worktree: feature.worktree, lastDeliveredToAnySessionID: newer.id),
            teamID: "acme"
        )

        let advanced = try inbox.compareAndAdvanceWorktreeWatermark(
            teamID: "acme",
            worktree: feature.worktree,
            to: older.id
        )

        #expect(!advanced)
        #expect(try inbox.worktreeWatermark(
            teamID: "acme",
            worktree: feature.worktree
        )?.lastDeliveredToAnySessionID == newer.id)
    }

    @Test func writeWorktreeWatermarkRefusesToRegress() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "m").next,
            now: { Date(timeIntervalSince1970: 4_050) }
        )
        let sender = TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude")
        let feature = TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: nil)

        let older = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "older")
        let newer = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "newer")
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(worktree: feature.worktree, lastDeliveredToAnySessionID: newer.id),
            teamID: "acme"
        )

        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(worktree: feature.worktree, lastDeliveredToAnySessionID: older.id),
            teamID: "acme"
        )

        #expect(try inbox.worktreeWatermark(
            teamID: "acme",
            worktree: feature.worktree
        )?.lastDeliveredToAnySessionID == newer.id)
    }

    @Test func compareAndAdvanceWorktreeWatermarkAdvancesWhenNewer() throws {
        let inbox = TeamInbox(
            rootDirectory: try temporaryDirectory(),
            idGenerator: IncrementingIDGenerator(prefix: "m").next,
            now: { Date(timeIntervalSince1970: 4_100) }
        )
        let sender = TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude")
        let feature = TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: nil)

        let older = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "older")
        let newer = try inbox.appendMessage(teamID: "acme", teamName: "acme-web", repoPath: "/repo/acme", from: sender, to: feature, priority: .normal, body: "newer")
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(worktree: feature.worktree, lastDeliveredToAnySessionID: older.id),
            teamID: "acme"
        )

        let advanced = try inbox.compareAndAdvanceWorktreeWatermark(
            teamID: "acme",
            worktree: feature.worktree,
            to: newer.id
        )

        #expect(advanced)
        #expect(try inbox.worktreeWatermark(
            teamID: "acme",
            worktree: feature.worktree
        )?.lastDeliveredToAnySessionID == newer.id)
    }

    @Test("@spec TEAM-11.6: If the worktree watermark lock cannot be acquired within the configured timeout, the application shall throw a lock-timeout error instead of blocking the calling thread indefinitely.")
    func watermarkLockAcquisitionIsBounded() throws {
        let root = try temporaryDirectory()
        let worktree = "/repo/acme/.worktrees/feature-auth"
        let holder = try TeamTestFixtures.holdWatermarkLock(
            root: root,
            teamID: "acme",
            worktree: worktree
        )
        defer { holder.release() }

        let inbox = TeamInbox(rootDirectory: root, watermarkLockTimeout: 0.3)
        let start = Date()
        #expect(throws: TeamInboxError.watermarkLockTimeout) {
            try inbox.compareAndAdvanceWorktreeWatermark(
                teamID: "acme",
                worktree: worktree,
                to: "m1"
            )
        }
        // The call must give up promptly — this is the whole point.
        #expect(Date().timeIntervalSince(start) < 5)
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

@Suite("TeamInboxMessage — agent_prompt forward-compat")
struct TeamInboxMessageAgentPromptCodableTests {
    @Test("Round-trip: a row with agentPrompt set encodes the agent_prompt JSON key.")
    func roundTripWithPrompt() throws {
        let msg = TeamInboxMessage(
            id: "id-1",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "team",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: "/repo/.worktrees/alice", runtime: nil),
            priority: .normal,
            kind: "team_message",
            body: "ping",
            agentPrompt: "Hi alice — context: ping"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"agent_prompt\":\"Hi alice — context: ping\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TeamInboxMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test("Round-trip: a row without agentPrompt encodes the JSON without an agent_prompt key.")
    func roundTripWithoutPrompt() throws {
        let msg = TeamInboxMessage(
            id: "id-2",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "team",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: "/repo/.worktrees/alice", runtime: nil),
            priority: .normal,
            kind: "team_message",
            body: "ping",
            agentPrompt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("agent_prompt"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TeamInboxMessage.self, from: data)
        #expect(decoded.agentPrompt == nil)
    }

    @Test("Forward-compat: a legacy row on disk (no agent_prompt key) decodes with agentPrompt = nil.")
    func decodeLegacyRow() throws {
        let legacy = """
        {"id":"id-3","created_at":"1970-01-01T00:30:00Z","team":"team","repo_path":"/repo","from":{"member":"main","worktree":"/repo","runtime":null},"to":{"member":"alice","worktree":"/repo/.worktrees/alice","runtime":null},"priority":"normal","kind":"team_message","body":"legacy"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TeamInboxMessage.self, from: Data(legacy.utf8))
        #expect(decoded.agentPrompt == nil)
        #expect(decoded.body == "legacy")
    }
}
