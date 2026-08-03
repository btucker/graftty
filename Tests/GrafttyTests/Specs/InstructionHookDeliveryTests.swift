import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-6.3: When rendering session-start hook output, the application shall emit instruction content as its own section alongside the team context and queued messages, so that a blank team session template suppresses the team context without suppressing instructions.")
struct InstructionHookDeliveryTests {

    private func additionalContext(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let root = try #require(object as? [String: Any])
        let output = try #require(root["hookSpecificOutput"] as? [String: Any])
        return try #require(output["additionalContext"] as? String)
    }

    @Test func instructionsAppearAlongsideTeamContext() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .claude,
            teamContext: "TEAM CONTEXT",
            instructions: "INSTRUCTIONS"
        )
        let context = try additionalContext(json)
        #expect(context.contains("TEAM CONTEXT"))
        #expect(context.contains("INSTRUCTIONS"))
    }

    @Test func blankTeamTemplateStillDeliversInstructions() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .claude,
            teamContext: "",
            instructions: "INSTRUCTIONS"
        )
        let context = try additionalContext(json)
        #expect(context.contains("INSTRUCTIONS"))
    }

    @Test func emptyInstructionsAddNoSection() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .claude,
            teamContext: "TEAM CONTEXT",
            instructions: ""
        )
        let context = try additionalContext(json)
        #expect(context == "TEAM CONTEXT")
    }

    @Test func instructionsCoexistWithQueuedMessages() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .codex,
            teamContext: "TEAM CONTEXT",
            instructions: "INSTRUCTIONS",
            messages: [
                TeamInboxMessage.fixtureForInstructionTests(body: "QUEUED"),
            ]
        )
        let context = try additionalContext(json)
        #expect(context.contains("TEAM CONTEXT"))
        #expect(context.contains("INSTRUCTIONS"))
        #expect(context.contains("QUEUED"))
    }
}

private extension TeamInboxMessage {
    static func fixtureForInstructionTests(body: String) -> TeamInboxMessage {
        TeamInboxMessage(
            id: "m1",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            team: "team-x",
            repoPath: "/repo",
            from: TeamInboxEndpoint(
                member: "peer",
                worktree: "/repo/.worktrees/peer",
                runtime: "claude"
            ),
            to: TeamInboxEndpoint(
                member: "me",
                worktree: "/repo/.worktrees/me",
                runtime: "claude"
            ),
            priority: .normal,
            kind: "team_message",
            body: body
        )
    }
}
