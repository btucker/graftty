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

    @Test("Stop hook emits an empty object regardless of inbox contents — neither runtime accepts hookSpecificOutput on Stop, so any payload would fail the runtime's JSON-schema validation.")
    func codexStopAlwaysEmitsEmptyObject() throws {
        #expect(try TeamHookRenderer.codexStop(messages: []) == "{}")
        #expect(try TeamHookRenderer.codexStop(messages: [
            message(id: "m1", priority: .normal, body: "Please review my diff."),
            message(id: "m2", priority: .urgent, body: "CI is blocking you"),
        ]) == "{}")
        #expect(try TeamHookRenderer.claudeStop(messages: [
            message(id: "m1", priority: .normal, body: "anything"),
        ]) == "{}")
    }

    @Test func emptyMessagePostToolUseRendersEmptyObject() throws {
        #expect(try TeamHookRenderer.codexPostToolUse(messages: []) == "{}")
    }

    @Test("@spec TEAM-PRESENCE-1.1: When an agent session starts, the application shall inject a team protocol primer in the SessionStart additionalContext.")
    func sessionStartIncludesPrimer() throws {
        let json = try TeamHookRenderer.sessionStart(runtime: .codex, teamContext: "team data here")
        let context = try additionalContext(from: json)

        #expect(context.contains("graftty team register"))
        #expect(context.contains("graftty team inbox"))
        #expect(context.contains("graftty team send"))
        #expect(context.contains("graftty team status"))
        #expect(context.contains("team data here"))
    }

    @Test("Both runtimes produce the identical SessionStart primer text.")
    func bothRuntimesAlign() throws {
        let claude = try TeamHookRenderer.sessionStart(runtime: .claude, teamContext: "X")
        let codex = try TeamHookRenderer.sessionStart(runtime: .codex, teamContext: "X")
        #expect(claude == codex)
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

