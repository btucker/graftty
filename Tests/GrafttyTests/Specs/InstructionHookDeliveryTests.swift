import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-6.3: When rendering session-start hook output, the application shall emit instruction content as its own section after the Graftty skill guidance and before queued messages, and shall add no section for empty instructions.")
struct InstructionHookDeliveryTests {

    private func additionalContext(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let root = try #require(object as? [String: Any])
        let output = try #require(root["hookSpecificOutput"] as? [String: Any])
        return try #require(output["additionalContext"] as? String)
    }

    @Test func instructionsFollowSkillGuidance() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .claude,
            instructions: "INSTRUCTIONS"
        )
        let context = try additionalContext(json)
        #expect(context == TeamHookRenderer.skillGuidance + "\n\n\nINSTRUCTIONS")
    }

    @Test func emptyInstructionsAddNoSection() throws {
        let json = try TeamHookRenderer.sessionStart(runtime: .claude, instructions: "")
        let context = try additionalContext(json)
        #expect(context == TeamHookRenderer.skillGuidance)
    }

    @Test func instructionsCoexistWithQueuedMessages() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .codex,
            instructions: "INSTRUCTIONS",
            messages: [
                TeamInboxMessage.fixtureForInstructionTests(body: "QUEUED"),
            ]
        )
        let context = try additionalContext(json)
        let instructions = try #require(context.range(of: "INSTRUCTIONS"))
        let queued = try #require(context.range(of: "QUEUED"))
        #expect(instructions.lowerBound < queued.lowerBound)
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
