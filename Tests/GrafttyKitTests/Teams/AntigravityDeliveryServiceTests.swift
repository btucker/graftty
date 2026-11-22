import Foundation
import Testing
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("""
@spec AGENT-6.174: When inbox rows are deliverable to a reachable Antigravity agent whose presence records a local agent server, the application shall send all of those rows as one message to that agent's conversation through the server and update shared delivery state only after the server accepts the message; if the server credential is unavailable or the server rejects the message, then the rows shall remain unread for hook delivery or retry.
""")
struct AntigravityDeliveryServiceTests {
    @Test func sendsEveryPendingRowInOneMessageThenAcknowledges() async throws {
        let fixture = try Fixture()
        let first = try fixture.append(body: "please review")
        let second = try fixture.append(body: "and rebase")

        await fixture.service.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        let calls = await fixture.client.calls
        #expect(calls.count == 1)
        #expect(calls.first?.content == TeamPeerMessageFormatter.context(messages: [first, second]))
        #expect(calls.first?.conversationID == fixture.conversationID)
        #expect(calls.first?.port == 50_201)
        #expect(calls.first?.token == "secret-token")
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        )?.lastDeliveredToAnySessionID == second.id)
        #expect(try fixture.deliveryEvents().last?.detail["outcome"] == "sent")
    }

    @Test func rejectedSendLeavesRowsUnread() async throws {
        let fixture = try Fixture(error: AntigravityAgentClientError.http(status: 401, body: "invalid CSRF token"))
        _ = try fixture.append(body: "please review")

        await fixture.service.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        #expect(await fixture.client.calls.count == 1)
        #expect(try fixture.inbox.worktreeWatermark(teamID: fixture.teamID, worktree: fixture.worktree) == nil)
        #expect(try fixture.deliveryEvents().last?.detail["outcome"] == "error_delivery")
    }

    @Test func missingCredentialLeavesRowsUnreadWithoutContactingTheServer() async throws {
        let fixture = try Fixture(token: nil)
        _ = try fixture.append(body: "please review")

        await fixture.service.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        #expect(await fixture.client.calls.isEmpty)
        #expect(try fixture.inbox.worktreeWatermark(teamID: fixture.teamID, worktree: fixture.worktree) == nil)
        #expect(try fixture.deliveryEvents().last?.detail["outcome"] == "skipped_missing_credential")
    }

    @Test func agentWithoutRecordedServerIsLeftToHookDelivery() async throws {
        let fixture = try Fixture(recordsServer: false)
        _ = try fixture.append(body: "please review")

        await fixture.service.onMessageArrival(team: fixture.teamID, worktree: fixture.worktree)

        #expect(await fixture.client.calls.isEmpty)
        #expect(try fixture.inbox.worktreeWatermark(teamID: fixture.teamID, worktree: fixture.worktree) == nil)
    }

    @Test func sendRequestTargetsTheConversationWithTheCredentialHeader() throws {
        let request = try AntigravityAgentClient.sendRequest(
            content: "hello",
            title: "Graftty team message",
            conversationID: "33baee6d-e7b9-450b-88d5-739d941230bf",
            port: 50_201,
            token: "secret-token"
        )

        #expect(request.url?.absoluteString
            == "http://127.0.0.1:50201/exa.language_server_pb.LanguageServerService/SendAgentMessage")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-codeium-csrf-token") == "secret-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "content": "hello",
            "recipient": "33baee6d-e7b9-450b-88d5-739d941230bf",
            "senderId": "graftty",
            "displayTitle": "Graftty team message",
        ])
    }

    private struct Fixture {
        let teamID = "/repo"
        let worktree = "/repo/feature"
        let conversationID = "33baee6d-e7b9-450b-88d5-739d941230bf"
        let root: URL
        let inbox: TeamInbox
        let client: StubClient
        let service: AntigravityDeliveryService

        init(error: Error? = nil, token: String? = "secret-token", recordsServer: Bool = true) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-antigravity-delivery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ids = TeamTestFixtures.SequentialMessageIDs()
            let inbox = TeamInbox(rootDirectory: root, idGenerator: { ids.next() })
            let client = StubClient(error: error)
            let presence = TeamPresenceRecord(
                teamID: teamID,
                worktree: worktree,
                runtime: .antigravity,
                paneSessionName: "graftty-aabbccdd",
                pid: 101,
                processStartTimeMicroseconds: 1_001,
                registeredAt: Date(timeIntervalSince1970: 10),
                runtimeSessionID: conversationID,
                transport: recordsServer
                    ? .antigravity(port: 50_201, conversationID: conversationID, tokenPath: "/tokens/101.token")
                    : nil
            )
            self.root = root
            self.inbox = inbox
            self.client = client
            self.service = AntigravityDeliveryService(
                inbox: inbox,
                presenceRecords: { [presence] },
                agentReachability: { _ in true },
                client: client,
                readToken: { path in path == "/tokens/101.token" ? token : nil },
                eventLog: TeamEventLog(rootDirectory: root)
            )
        }

        func deliveryEvents() throws -> [TeamEvent] {
            try TeamTestFixtures.events(root: root, teamID: teamID)
        }

        func append(body: String) throws -> TeamInboxMessage {
            try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: teamID,
                from: TeamInboxEndpoint(member: "main", worktree: teamID, runtime: nil),
                to: TeamInboxEndpoint(member: "feature", worktree: worktree, runtime: "antigravity"),
                priority: .normal,
                body: body
            )
        }
    }

    private actor StubClient: AntigravityAgentClienting {
        struct Call: Equatable {
            let content: String
            let conversationID: String
            let port: Int
            let token: String
        }

        private(set) var calls: [Call] = []
        private let error: Error?

        init(error: Error?) {
            self.error = error
        }

        func send(content: String, title: String, conversationID: String, port: Int, token: String) async throws {
            calls.append(Call(content: content, conversationID: conversationID, port: port, token: token))
            if let error { throw error }
        }
    }
}
