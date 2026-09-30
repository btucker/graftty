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

@Suite("Graftty Team skill instruction-file guidance")
struct InstructionFileSkillGuidanceTests {
    @Test("""
    @spec INSTR-6.4: The Graftty Team provider skill shall explain the repository-wide and hierarchical worktree instruction-file forms, per-path Application Support/current-worktree/main-checkout precedence, current-filesystem reads without a commit, peer-visible role descriptions above the private section, that agents create or modify instruction files only when authorized, and how to place an exact-worktree file where a new child's first session can see it.
    """)
    func teamSkillExplainsInstructionFiles() throws {
        let skill = try GrafttyTeamSkillText.load()

        #expect(skill.contains("`.graftty/GRAFTTY.md` applies to every worktree"))
        #expect(skill.contains("`.graftty/<parent>/<leaf>/GRAFTTY.md`"))
        #expect(skill.contains("path relative to the main checkout's `.worktrees/`"))
        #expect(skill.contains("main checkout's key is the repository's default branch"))
        #expect(skill.contains("Application Support, current worktree, then main checkout"))
        #expect(skill.contains("no commit is required"))
        #expect(skill.contains("## Private"))
        #expect(skill.contains("shared with peers"))
        #expect(skill.contains("only when authorized"))
        #expect(skill.contains("where its first session can see it"))
        #expect(skill.contains("--base HEAD"))
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
