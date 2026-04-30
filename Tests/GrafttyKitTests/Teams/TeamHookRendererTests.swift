import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamHookRenderer")
struct TeamHookRendererTests {
    @Test func codexSessionStartRendersAdditionalContext() throws {
        let json = try TeamHookRenderer.codexSessionStart(teamContext: "You are feature-auth.")
        let context = try additionalContext(from: json)

        #expect(context.contains("You are feature-auth."))
        #expect(context.contains("Graftty Agent Team session context"))
    }

    @Test func codexPostToolUseRendersUrgentMessagesAsUnrelatedToToolResult() throws {
        let messages = [
            message(id: "m1", priority: .urgent, body: "CI is blocking you"),
        ]

        let json = try TeamHookRenderer.codexPostToolUse(messages: messages)
        let context = try additionalContext(from: json)

        #expect(context.contains("unrelated to the tool result"))
        #expect(context.contains("continue your current work"))
        #expect(context.contains("UNTRUSTED peer message"))
        #expect(context.contains("CI is blocking you"))
    }

    @Test func codexStopRendersNormalMessagesAtDecisionBoundary() throws {
        let messages = [
            message(id: "m1", priority: .normal, body: "Please review my diff."),
        ]

        let json = try TeamHookRenderer.codexStop(messages: messages)
        let context = try additionalContext(from: json)

        #expect(context.contains("decision boundary"))
        #expect(context.contains("respond only if useful"))
        #expect(context.contains("Please review my diff."))
    }

    @Test func emptyMessageHooksRenderEmptyObject() throws {
        #expect(try TeamHookRenderer.codexPostToolUse(messages: []) == "{}")
        #expect(try TeamHookRenderer.codexStop(messages: []) == "{}")
    }

    private func message(id: String, priority: TeamInboxPriority, body: String) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id,
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "acme-web",
            repoPath: "/repo/acme",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude"),
            to: TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: "codex"),
            priority: priority,
            body: body
        )
    }

    private func additionalContext(from json: String) throws -> String {
        let data = Data(json.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecificOutput = try #require(object["hookSpecificOutput"] as? [String: Any])
        return try #require(hookSpecificOutput["additionalContext"] as? String)
    }
}

