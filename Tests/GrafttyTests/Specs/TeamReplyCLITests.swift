import ArgumentParser
import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

@Suite("graftty team reply")
struct TeamReplyCLITests {
    @Test func parsesMessageIDAndExplicitFallback() throws {
        let command = try TeamReply.parse(["message-123", "--stdin", "--urgent", "--fallback"])
        #expect(command.messageID == "message-123")
        #expect(command.stdin)
        #expect(command.urgent)
        #expect(command.fallback)
        #expect(Team.helpMessage().contains("reply"))
        #expect(throws: (any Error).self) { try TeamReply.parse([]) }
    }

    @Test func submitsOneReplyRequestWithoutLookingUpNamesOrRetrying() throws {
        let command = try TeamReply.parse(["message-123", "--stdin"])
        var requests: [NotificationMessage] = []
        #expect(throws: (any Error).self) {
            try command.execute(callerWorktree: "/repo", callerAgentID: "codex-012345abcdef", body: "reply") { request in
                requests.append(request)
                return .error("Delivery may have occurred")
            }
        }
        let expected = NotificationMessage.teamReply(callerWorktree: "/repo", callerAgentID: "codex-012345abcdef", messageID: "message-123", text: "reply", priority: .normal, fallback: false)
        #expect(requests == [expected])
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(expected)) == expected)
    }
}
