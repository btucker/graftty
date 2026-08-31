import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamHookRenderer")
struct TeamHookRendererTests {
    @Test func codexSessionStartRendersAdditionalContext() throws {
        let json = try TeamHookRenderer.codexSessionStart(teamContext: "You are feature-auth.")
        let context = try additionalContext(from: json)

        #expect(context == "You are feature-auth.")
        #expect(!context.contains("Graftty team context"))
    }

    @Test func claudePostToolUseRendersUrgentMessagesAsUnrelatedToToolResult() throws {
        let messages = [
            message(id: "m1", priority: .urgent, body: "CI is blocking you"),
        ]

        let json = try TeamHookRenderer.claudePostToolUse(messages: messages)
        let context = try additionalContext(from: json)

        #expect(context.contains("unrelated to the tool result"))
        #expect(context.contains("continue your current work"))
        #expect(context.contains("<graftty-peer-message agent=\"/repo/acme\" fallback-agent=\"/repo/acme#claude\" priority=\"urgent\">"))
        #expect(!context.lowercased().contains("untrusted"))
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

    @Test("@spec TEAM-PRESENCE-1.1: The built-in `teamSessionPrompt` shall include the Graftty team protocol primer in SessionStart additionalContext. A user may replace or clear that complete template in Agent Teams Settings.")
    func sessionStartIncludesPrimer() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .codex,
            teamContext: defaultTeamContext()
        )
        let context = try additionalContext(from: json)

        #expect(context.contains("graftty team inbox"))
        #expect(context.contains("graftty team send --stdin"))
        #expect(context.contains("graftty team list"))
        #expect(context.contains("feature/auth"))
        #expect(!context.lowercased().contains("coworker"))
        #expect(!context.lowercased().contains("lead"))

        // TEAM-PRESENCE-1.3: registration is handled by the wrapper, not
        // typed by the model. The primer must not instruct it — that's the
        // shape the classifier kept blocking.
        #expect(!context.contains("graftty team register"))
    }

    @Test("@spec TEAM-4.4: The built-in session-start template shall instruct agents to send direct and broadcast message bodies through standard input with a quoted, freshly generated heredoc delimiter that is absent from the message, never as a shell argument, so shell syntax in messages remains literal.")
    func sessionStartDocumentsLiteralMessageInput() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .codex,
            teamContext: defaultTeamContext()
        )
        let context = try additionalContext(from: json)

        #expect(context.contains("graftty team send --stdin"))
        #expect(context.contains("graftty team broadcast --stdin"))
        #expect(context.contains("<graftty-peer-message agent=\"<exact-address>\" fallback-agent=\"<runtime-address>\">"))
        #expect(context.contains("<graftty-forge-message provider=\"<provider>\">"))
        #expect(context.contains("<graftty-system-message>"))
        #expect(context.contains("stable reply address"))
        #expect(context.contains("send to `fallback-agent`"))
        #expect(context.contains("<<'GRAFTTY_<random>'"))
        #expect(context.contains("fresh quoted high-entropy heredoc delimiter"))
        #expect(context.contains("absent from the body"))
        #expect(context.contains("never use it literally"))
        #expect(!context.contains("GRAFTTY_MSG_7F3A"))
        #expect(context.contains("Quoting keeps shell syntax literal"))
        #expect(context.contains("never shell arguments"))
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
        #expect(!rendered.contains("[id="))
        #expect(!rendered.contains("priority="))
        #expect(!rendered.contains("runtime="))
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

    @Test("A normal worktree message has a compact canonical attribution and no internal event metadata.")
    func formatWorktreeMessage() {
        let msg = message(
            id: "opaque-id",
            priority: .normal,
            body: "Please check the parser.",
            agentPrompt: "A Graftty automated team event was just delivered to you."
        )

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered == """
        <graftty-peer-message agent="/repo/acme" fallback-agent="/repo/acme#claude">
        Please check the parser.
        </graftty-peer-message>
        """)
        #expect(!rendered.contains("opaque-id"))
        #expect(!rendered.contains("runtime="))
        #expect(!rendered.contains("automated team event"))
    }

    @Test("An urgent worktree message carries an explicit urgency marker so the post-tool-use preamble's urgent carve-out can fire.")
    func formatUrgentWorktreeMessage() {
        let msg = message(id: "m1", priority: .urgent, body: "This blocks the merge.")

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered == """
        <graftty-peer-message agent="/repo/acme" fallback-agent="/repo/acme#claude" priority="urgent">
        This blocks the merge.
        </graftty-peer-message>
        """)
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

    private func defaultTeamContext() -> String {
        var repo = RepoEntry(path: "/repo/acme", displayName: "acme")
        repo.worktrees.append(WorktreeEntry(path: "/repo/acme", branch: "main"))
        repo.worktrees.append(
            WorktreeEntry(
                path: "/repo/acme/.worktrees/feature-auth",
                branch: "feature/auth"
            )
        )
        let team = TeamView.team(
            for: repo.worktrees[1],
            in: [repo],
            teamsEnabled: true
        )!
        return TeamInstructionsRenderer.render(team: team, viewer: team.members[1])
    }
}
