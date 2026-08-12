import Foundation
import Testing
@testable import GrafttyKit

@Suite("Claude native peer delivery")
struct ClaudePeerDeliveryServiceTests {
    @Test("""
    @spec AGENT-6.6: When an inbox row is bound to a reachable protocol-v1 Claude agent, the application shall send the leading same-sender run of the pending exact-agent prefix through Claude's native peer socket and advance the shared worktree watermark only after the socket accepts the full frame; on discovery or transport failure, the row shall remain unread for wrapper fallback or retry.
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
        let inbox: TeamInbox
        let client: StubClient
        let service: ClaudePeerDeliveryService
        let agentID: String

        init(error: Error? = nil, includeEarlierCodex: Bool = false) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-claude-delivery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let counter = IDCounter()
            let inbox = TeamInbox(rootDirectory: root, idGenerator: { counter.next() })
            let client = StubClient(error: error)
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
            self.inbox = inbox
            self.client = client
            self.agentID = agentID
            self.service = ClaudePeerDeliveryService(
                inbox: inbox,
                presenceRecords: { records },
                agentReachability: { _ in true },
                client: client,
                eventLog: nil
            )
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

        init(error: Error?) {
            self.error = error
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
            return UUID()
        }
    }
}
