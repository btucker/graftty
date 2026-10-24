import Testing
import ArgumentParser
import GrafttyKit
@testable import GrafttyCLI

@Suite("@spec TEAM-4.14: When `graftty team msg <address> <text>` is invoked, the CLI shall validate the body and send a normal-priority `team_send` request as a hidden alias of `team send` that `graftty team --help` does not list; if the body is empty, then the CLI shall reject it before sending.")
struct TeamMsgAliasCLITests {
    @Test func msgStillParses() throws {
        let command = try GrafttyCLI.parseAsRoot(["team", "msg", "/r/b", "hi"])
        let msg = try #require(command as? TeamMsg)
        #expect(try msg.request(callerWorktree: "/r/a", callerAgentID: "codex-1")
            == .teamSend(callerWorktree: "/r/a", callerAgentID: "codex-1", recipient: "/r/b", text: "hi",
                         priority: .normal))
    }

    @Test("An empty team msg body is rejected before a request can be sent")
    func emptyMessageIsRejected() throws {
        let command = try TeamMsg.parse(["bob", ""])
        let buildRequest: (String, String?) throws -> NotificationMessage = command.request
        do {
            _ = try buildRequest("/r/a", "codex-1")
            Issue.record("team msg built a send request with an empty body")
        } catch let error as ValidationError {
            #expect(String(describing: error).contains("message text is required"))
        }
    }

    @Test func msgIsHiddenFromHelp() {
        #expect(TeamMsg.configuration.shouldDisplay == false)
        #expect(!Team.helpMessage().contains("msg"))
    }

    @Test("Dash-prefixed alias arguments remain literal message values")
    func dashPrefixedArgumentsRemainLiteral() throws {
        let command = try TeamMsg.parse(["--", "--stdin", "--urgent"])
        #expect(try command.request(callerWorktree: "/r/a", callerAgentID: "codex-1")
            == .teamSend(callerWorktree: "/r/a", callerAgentID: "codex-1", recipient: "--stdin",
                         text: "--urgent", priority: .normal))
    }
}
