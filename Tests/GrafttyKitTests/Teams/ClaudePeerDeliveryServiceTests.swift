import Foundation
import Testing
@testable import GrafttyKit

@Suite("Claude native peer delivery")
struct ClaudePeerDeliveryServiceTests {
    @Test("""
    @spec AGENT-6.6: When an inbox row is bound to a reachable protocol-v1 Claude agent, the application shall send the pending exact-agent prefix through Claude's native peer socket and advance the shared worktree watermark only after the socket accepts the full frame; on discovery or transport failure, the row shall remain unread for wrapper fallback or retry.
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
        #expect(calls[0].body.contains("please review"))
        #expect(calls[0].body.contains("<graftty-peer-message agent=\"/repo\">"))
        #expect(!calls[0].body.contains("untrusted"))
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
            let inbox = TeamInbox(rootDirectory: root, idGenerator: { "message-1" })
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

        func append(body: String, exact: Bool = true) throws -> TeamInboxMessage {
            try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: teamID,
                from: TeamInboxEndpoint(member: "main", worktree: teamID, runtime: nil),
                to: TeamInboxEndpoint(
                    member: "feature",
                    worktree: worktree,
                    runtime: "claude",
                    agentID: exact ? agentID : nil
                ),
                priority: .normal,
                body: body
            )
        }
    }

    private enum StubError: Error { case failed }

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
