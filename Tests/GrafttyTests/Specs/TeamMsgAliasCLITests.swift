import Testing
@testable import GrafttyCLI

@Suite("@spec TEAM-4.14: When `graftty team msg <address> <text>` is invoked, the CLI shall send a normal-priority `team_send` request as a hidden alias of `team send` that `graftty team --help` does not list.")
struct TeamMsgAliasCLITests {
    @Test func msgStillParses() throws {
        let command = try GrafttyCLI.parseAsRoot(["team", "msg", "/r/b", "hi"])
        let msg = try #require(command as? TeamMsg)
        #expect(msg.request(callerWorktree: "/r/a", callerAgentID: "codex-1")
            == .teamSend(callerWorktree: "/r/a", callerAgentID: "codex-1", recipient: "/r/b", text: "hi",
                         priority: .normal))
    }

    @Test func msgIsHiddenFromHelp() {
        #expect(TeamMsg.configuration.shouldDisplay == false)
        #expect(!Team.helpMessage().contains("msg"))
    }
}
