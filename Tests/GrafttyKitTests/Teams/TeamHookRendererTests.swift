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

    @Test func claudePostToolUseRendersUrgentMessagesAsUnrelatedToToolResult() throws {
        let messages = [
            message(id: "m1", priority: .urgent, body: "CI is blocking you"),
        ]

        let json = try TeamHookRenderer.claudePostToolUse(messages: messages)
        let context = try additionalContext(from: json)

        #expect(context.contains("unrelated to the tool result"))
        #expect(context.contains("continue your current work"))
        #expect(context.contains("UNTRUSTED peer message"))
        #expect(context.contains("CI is blocking you"))
    }

    @Test("Codex PostToolUse is a no-op because Codex delivery uses the app-server path.")
    func codexPostToolUseAlwaysEmitsEmptyObject() throws {
        #expect(try TeamHookRenderer.postToolUse(runtime: .codex, messages: []) == "{}")
        #expect(try TeamHookRenderer.postToolUse(runtime: .codex, messages: [
            message(id: "m1", priority: .urgent, body: "CI is blocking you"),
        ]) == "{}")
    }

    @Test("Stop hook emits an empty object regardless of inbox contents.")
    func stopAlwaysEmitsEmptyObject() throws {
        #expect(try TeamHookRenderer.stop(runtime: .codex, messages: []) == "{}")
        #expect(try TeamHookRenderer.stop(runtime: .claude, messages: [
            message(id: "m1", priority: .normal, body: "anything"),
        ]) == "{}")
    }

    @Test func emptyMessagePostToolUseRendersEmptyObject() throws {
        #expect(try TeamHookRenderer.claudePostToolUse(messages: []) == "{}")
    }

    @Test("@spec TEAM-PRESENCE-1.1: When an agent session starts, the application shall inject a team protocol primer in the SessionStart additionalContext.")
    func sessionStartIncludesPrimer() throws {
        let json = try TeamHookRenderer.sessionStart(runtime: .codex, teamContext: "team data here")
        let context = try additionalContext(from: json)

        #expect(context.contains("graftty team inbox"))
        #expect(context.contains("graftty team send --stdin"))
        #expect(context.contains("graftty team list"))
        #expect(context.contains("team data here"))
        #expect(!context.lowercased().contains("coworker"))
        #expect(!context.lowercased().contains("lead"))

        // TEAM-PRESENCE-1.3: registration is handled by the wrapper, not
        // typed by the model. The primer must not instruct it — that's the
        // shape the classifier kept blocking.
        #expect(!context.contains("graftty team register"))
    }

    @Test("@spec TEAM-4.4: The session-start team primer shall instruct agents to send direct and broadcast message bodies through standard input with a quoted, freshly generated heredoc delimiter that is absent from the message, never as a shell argument, so shell syntax in messages remains literal.")
    func sessionStartDocumentsLiteralMessageInput() throws {
        let json = try TeamHookRenderer.sessionStart(runtime: .codex, teamContext: "team data here")
        let context = try additionalContext(from: json)

        #expect(context.contains("graftty team send --stdin"))
        #expect(context.contains("graftty team broadcast --stdin"))
        #expect(context.contains("worktree message from <address>"))
        #expect(context.contains("stable reply address"))
        #expect(context.contains("Reply with `graftty team send --stdin <address>`"))
        #expect(context.contains("<<'<unique-delimiter>'"))
        #expect(context.contains("newly generated high-entropy value"))
        #expect(context.contains("does not appear as an exact line"))
        #expect(context.contains("Do not run the placeholder literally"))
        #expect(!context.contains("GRAFTTY_MSG_7F3A"))
        #expect(context.contains("backticks"))
        #expect(context.contains("$()"))
        #expect(context.contains("never as a shell argument"))
        #expect(!context.contains("graftty team msg"))
    }

    @Test("Both runtimes produce the identical SessionStart primer text.")
    func bothRuntimesAlign() throws {
        let claude = try TeamHookRenderer.sessionStart(runtime: .claude, teamContext: "X")
        let codex = try TeamHookRenderer.sessionStart(runtime: .codex, teamContext: "X")
        #expect(claude == codex)
    }

    @Test("format(messages:) emits agentPrompt when non-nil.")
    func formatEmitsAgentPromptWhenPresent() {
        let msg = message(
            id: "m1",
            priority: .normal,
            kind: TeamChannelEvents.WireType.prStateChanged,
            body: "EVENT-BODY",
            agentPrompt: "Hello alice.\n\nEVENT-BODY"
        )
        let rendered = TeamHookRenderer.format(messages: [msg])
        #expect(rendered.contains("Hello alice."))
        #expect(rendered.contains("EVENT-BODY"))
        // The prompt already contains the body content; we shouldn't see
        // the body emitted a SECOND time after the prompt.
        #expect(rendered.components(separatedBy: "EVENT-BODY").count - 1 == 1)
    }

    @Test("format(messages:) falls through to body when agentPrompt is nil.")
    func formatFallsThroughToBodyWhenPromptNil() {
        let msg = message(
            id: "m1",
            priority: .normal,
            kind: TeamChannelEvents.WireType.prStateChanged,
            body: "RAW-EVENT",
            agentPrompt: nil
        )
        let rendered = TeamHookRenderer.format(messages: [msg])
        #expect(rendered.contains("RAW-EVENT"))
    }

    @Test("A normal worktree message has a compact attribution and no internal event metadata.")
    func formatWorktreeMessage() {
        let msg = message(
            id: "opaque-id",
            priority: .normal,
            body: "Please check the parser.",
            agentPrompt: "A Graftty automated team event was just delivered to you."
        )

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered == "Worktree message from `main`:\n\nPlease check the parser.")
        #expect(!rendered.contains("opaque-id"))
        #expect(!rendered.contains("runtime="))
        #expect(!rendered.contains("automated team event"))
    }

    @Test("An urgent worktree message labels only its actionable priority.")
    func formatUrgentWorktreeMessage() {
        let msg = message(id: "m1", priority: .urgent, body: "This blocks the merge.")

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered == "Urgent worktree message from `main`:\n\nThis blocks the merge.")
    }

    private func message(
        id: String,
        priority: TeamInboxPriority,
        kind: String = TeamChannelEvents.EventType.message,
        body: String,
        agentPrompt: String? = nil
    ) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id,
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "acme-web",
            repoPath: "/repo/acme",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude"),
            to: TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: "codex"),
            priority: priority,
            kind: kind,
            body: body,
            agentPrompt: agentPrompt
        )
    }

    private func additionalContext(from json: String) throws -> String {
        let data = Data(json.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecificOutput = try #require(object["hookSpecificOutput"] as? [String: Any])
        return try #require(hookSpecificOutput["additionalContext"] as? String)
    }
}
