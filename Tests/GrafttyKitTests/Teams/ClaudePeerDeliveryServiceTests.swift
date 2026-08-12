import Foundation
import Testing
@testable import GrafttyKit

@Suite("Claude native peer delivery")
struct ClaudePeerDeliveryServiceTests {
    @Test("""
    @spec AGENT-6.6: When an inbox row is bound to a reachable protocol-v1 Claude agent, the application shall send the leading same-sender run of the pending exact-agent prefix through Claude's native peer socket and advance the shared worktree watermark only after the socket accepts the full frame, except that a lone row exceeding the frame cap shall be skipped by advancing the watermark past it; on discovery or transport failure, the row shall remain unread for wrapper fallback or retry.
    """)
    func exactAgentDeliveryAdvancesOnlyAfterAcceptance() async throws {
        let fixture = try Fixture()
        let message = try fixture.append(body: "please review")

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        let calls = await fixture.client.calls
        #expect(calls.count == 1)
        #expect(calls[0].socketPath == fixture.socketPath)
        #expect(calls[0].body == "please review")
        #expect(!calls[0].body.contains("<graftty-peer-message"))
        #expect(calls[0].senderName == "repo/main")
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        )?.lastDeliveredToAnySessionID == message.id)
    }

    @Test("Transport failure leaves exact row unread.")
    func failureLeavesRowUnread() async throws {
        let fixture = try Fixture(error: StubError.failed)
        _ = try fixture.append(body: "please review")

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        ) == nil)
    }

    @Test("An oversized lone row is skipped past so it cannot wedge the worktree queue.")
    func oversizedSingleRowIsSkippedPast() async throws {
        let fixture = try Fixture(errorForBody: { body in
            body.contains("OVERSIZED")
                ? ClaudePeerMessagingError.messageTooLarge(bytes: 99_999, maxBytes: 1)
                : nil
        })
        let oversized = try fixture.append(body: "OVERSIZED payload")
        let deliverable = try fixture.append(body: "please review")

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        // Batch of two overflows, halves to the oversized row alone, which
        // still overflows and is skipped; the next pass delivers the rest.
        let calls = await fixture.client.calls
        #expect(calls.map(\.body) == [
            "OVERSIZED payload\n\nplease review",
            "OVERSIZED payload",
            "please review",
        ])
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        )?.lastDeliveredToAnySessionID == deliverable.id)
        let skip = try fixture.deliveryEvents().first {
            $0.detail["outcome"] == "skipped_oversized"
        }
        #expect(skip?.detail["messageIDs"] == oversized.id)
    }

    @Test("A watermark-commit failure after an accepted send logs error_watermark_write, not error_delivery.")
    func watermarkCommitFailureIsNotASendFailure() async throws {
        let fixture = try Fixture()
        let first = try fixture.append(body: "first")
        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )
        let second = try fixture.append(body: "second")
        // The first delivery materialized the worktrees/ watermark directory;
        // making it read-only makes the next atomic watermark write throw
        // while reads (and the already-created lock file) keep working.
        let worktreesDir = fixture.root
            .appendingPathComponent(TeamInbox.fileComponent(fixture.teamID), isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: worktreesDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: worktreesDir.path
            )
        }

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        #expect(await fixture.client.calls.count == 2)
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        )?.lastDeliveredToAnySessionID == first.id)
        let outcomes = try fixture.deliveryEvents().map { $0.detail["outcome"] }
        #expect(!outcomes.contains("error_delivery"))
        let failure = try fixture.deliveryEvents().first {
            $0.detail["outcome"] == "error_watermark_write"
        }
        #expect(failure?.detail["messageIDs"] == second.id)
    }

    @Test("A send failure after halving logs the shrunk batch's ids, not the whole run's.")
    func sendFailureLogsActualBatchIDs() async throws {
        let fixture = try Fixture(errorForBody: { body in
            if body.contains("\n\n") {
                return ClaudePeerMessagingError.messageTooLarge(bytes: 99_999, maxBytes: 1)
            }
            return body == "first" ? StubError.failed : nil
        })
        let first = try fixture.append(body: "first")
        _ = try fixture.append(body: "second")

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        #expect(await fixture.client.calls.map(\.body) == ["first\n\nsecond", "first"])
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        ) == nil)
        let failure = try fixture.deliveryEvents().first {
            $0.detail["outcome"] == "error_delivery"
        }
        #expect(failure?.detail["messageIDs"] == first.id)
    }

    @Test("""
    @spec AGENT-6.19: When pending deliverable rows are sent through Claude's native peer socket, the application shall send only the leading run of rows sharing one derived sender name per frame, with bodies joined by a blank line and no per-message envelope, leaving later runs for subsequent frames.
    """)
    func mixedSendersSplitIntoPerSenderFrames() async throws {
        let fixture = try Fixture()
        let codexSender = TeamInboxEndpoint(
            member: "main",
            worktree: fixture.teamID,
            runtime: "codex",
            agentID: "codex-0123456789ab"
        )
        _ = try fixture.append(body: "first", from: codexSender)
        _ = try fixture.append(body: "second", from: codexSender)
        _ = try fixture.append(body: "PR #42 opened", from: .system(repoPath: fixture.teamID), source: "github")
        let last = try fixture.append(body: "roster changed", from: .system(repoPath: fixture.teamID))

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        let calls = await fixture.client.calls
        #expect(calls.count == 3)
        #expect(calls[0].body == "first\n\nsecond")
        #expect(calls[0].senderName == "repo/main#codex-0123456789ab")
        #expect(calls[1].body == "PR #42 opened")
        #expect(calls[1].senderName == "GitHub")
        #expect(calls[2].body == "roster changed")
        #expect(calls[2].senderName == "Graftty team")
        #expect(calls.allSatisfy { !$0.body.contains("<graftty-peer-message") })
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        )?.lastDeliveredToAnySessionID == last.id)
    }

    @Test("A Claude-qualified default ignores an earlier Codex agent.")
    func runtimeDefaultSelectsClaude() async throws {
        let fixture = try Fixture(includeEarlierCodex: true)
        let message = try fixture.append(body: "please review", exact: false)

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        #expect(await fixture.client.calls.count == 1)
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        )?.lastDeliveredToAnySessionID == message.id)
    }

    private struct Fixture {
        let teamID = "/repo"
        let worktree = "/repo/feature"
        let socketPath = "/tmp/cc-socks/101.sock"
        let root: URL
        let inbox: TeamInbox
        let client: StubClient
        let service: ClaudePeerDeliveryService
        let agentID: String

        init(
            error: Error? = nil,
            includeEarlierCodex: Bool = false,
            errorForBody: (@Sendable (String) -> Error?)? = nil
        ) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-claude-delivery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let counter = IDCounter()
            let inbox = TeamInbox(rootDirectory: root, idGenerator: { counter.next() })
            let client = StubClient(error: error, errorForBody: errorForBody)
            let agentID = TeamAgentIdentity(runtime: .claude, nativeSessionID: "session-1").rawValue
            let presence = TeamPresenceRecord(
                teamID: teamID,
                worktree: worktree,
                runtime: .claude,
                paneSessionName: "graftty-aabbccdd",
                pid: 101,
                processStartTimeMicroseconds: 1_001,
                registeredAt: Date(timeIntervalSince1970: 10),
                runtimeSessionID: "session-1",
                agentID: agentID,
                transport: .claude(socketPath: socketPath, protocolVersion: 1)
            )
            let codexPresence = TeamPresenceRecord(
                teamID: teamID,
                worktree: worktree,
                runtime: .codex,
                paneSessionName: "graftty-codex",
                pid: 100,
                processStartTimeMicroseconds: 1_000,
                registeredAt: Date(timeIntervalSince1970: 1),
                runtimeSessionID: "codex-earlier"
            )
            let records = includeEarlierCodex ? [codexPresence, presence] : [presence]
            self.root = root
            self.inbox = inbox
            self.client = client
            self.agentID = agentID
            self.service = ClaudePeerDeliveryService(
                inbox: inbox,
                presenceRecords: { records },
                agentReachability: { _ in true },
                client: client,
                eventLog: TeamEventLog(rootDirectory: root)
            )
        }

        func deliveryEvents() throws -> [TeamEvent] {
            let url = root
                .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
                .appendingPathComponent("events.jsonl")
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { try? decoder.decode(TeamEvent.self, from: Data($0.utf8)) }
        }

        func append(
            body: String,
            exact: Bool = true,
            from: TeamInboxEndpoint? = nil,
            source: String? = nil
        ) throws -> TeamInboxMessage {
            try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: teamID,
                from: from ?? TeamInboxEndpoint(member: "main", worktree: teamID, runtime: nil),
                to: TeamInboxEndpoint(
                    member: "feature",
                    worktree: worktree,
                    runtime: "claude",
                    agentID: exact ? agentID : nil
                ),
                priority: .normal,
                body: body,
                source: source
            )
        }
    }

    private enum StubError: Error { case failed }

    private final class IDCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            n += 1
            return "message-\(n)"
        }
    }

    private actor StubClient: ClaudePeerClienting {
        struct Call: Sendable {
            let body: String
            let socketPath: String
            let replySocketPath: String?
            let senderName: String?
        }

        private(set) var calls: [Call] = []
        let error: Error?
        let errorForBody: (@Sendable (String) -> Error?)?

        init(error: Error?, errorForBody: (@Sendable (String) -> Error?)? = nil) {
            self.error = error
            self.errorForBody = errorForBody
        }

        func send(
            body: String,
            socketPath: String,
            replySocketPath: String?,
            senderName: String?
        ) async throws -> UUID {
            calls.append(Call(
                body: body,
                socketPath: socketPath,
                replySocketPath: replySocketPath,
                senderName: senderName
            ))
            if let error { throw error }
            if let bodyError = errorForBody?(body) { throw bodyError }
            return UUID()
        }
    }
}
