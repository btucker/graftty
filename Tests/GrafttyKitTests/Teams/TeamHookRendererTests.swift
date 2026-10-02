import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamHookRenderer")
struct TeamHookRendererTests {
    @Test("@spec AGENT-6.33: When an agent session starts, the application shall instruct the agent to load the Graftty skill for Attention recaps and the Graftty Team skill for coordination and durable roles, and require a task-specific emoji independently of cached skill instructions.")
    func managedSessionLoadsGrafttySkill() throws {
        for runtime in [TeamHookRuntime.codex, .claude] {
            let json = try TeamHookRenderer.sessionStart(runtime: runtime)
            let context = try additionalContext(from: json)
            #expect(context.contains("Load the `graftty` skill for Attention recaps"))
            #expect(context.contains("`graftty-team` skill for agent coordination"))
            #expect(context.contains("durable roles"))
            #expect(context.contains("task-specific `emoji`"))
            #expect(context.contains("`emojiAlternatives`"))
        }
    }

    @Test("@spec AGENT-6.44: When an agent session starts, the application shall instruct the agent to keep one agent per worktree by never creating a worktree itself, including through git, provider worktree tools, or other skills, and to delegate new-worktree work with graftty worktree add and an agent.")
    func managedSessionForbidsManualWorktrees() throws {
        for runtime in [TeamHookRuntime.codex, .claude] {
            let json = try TeamHookRenderer.sessionStart(runtime: runtime)
            let context = try additionalContext(from: json)
            #expect(context.contains("one agent per worktree"))
            #expect(context.contains("`git worktree add`"))
            #expect(context.contains("`graftty worktree add <name> --agent"))
        }
    }

    @Test("Stop recap request uses a blocking decision.")
    func recapRequestUsesStopDecision() throws {
        let json = try #require(JSONSerialization.jsonObject(
            with: Data(TeamHookRenderer.requestRecap().utf8)
        ) as? [String: String])
        #expect(json["decision"] == "block")
        #expect(json["reason"]?.contains("graftty attention report --stdin") == true)
        #expect(json["reason"]?.contains("context") == true)
        #expect(json["reason"]?.contains("emojiAlternatives") == true)
        #expect(json["reason"]?.contains("already reported without an emoji") == true)
    }

    @Test("@spec AGENT-3.24: When the Stop hook requests an Attention recap, the application shall instruct the agent not to mention the report in its response unless the report command fails.")
    func recapRequestKeepsReportSilent() throws {
        let json = try #require(JSONSerialization.jsonObject(
            with: Data(TeamHookRenderer.requestRecap().utf8)
        ) as? [String: String])
        let reason = try #require(json["reason"])
        #expect(reason.contains("Do not mention the report"))
        #expect(reason.contains("If the command fails, say so"))
    }

    @Test("SessionStart appends GRAFTTY.md instructions after the skill guidance.")
    func sessionStartRendersInstructionsAfterSkillGuidance() throws {
        let json = try TeamHookRenderer.sessionStart(
            runtime: .codex,
            instructions: "You are feature-auth."
        )
        let context = try additionalContext(from: json)

        #expect(context.hasPrefix("Load the `graftty` skill"))
        #expect(context.hasSuffix("You are feature-auth."))
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

    @Test("@spec TEAM-PRESENCE-1.1: The Graftty Team provider skill shall document the team protocol commands for listing the roster, sending messages through standard input, and reading the inbox, and shall not instruct agents to register themselves, because the wrapper and plugin hooks own registration.")
    func teamSkillDocumentsProtocol() throws {
        let skill = try GrafttyTeamSkillText.load()

        #expect(skill.contains("graftty team inbox"))
        #expect(skill.contains("graftty team send --stdin"))
        #expect(skill.contains("graftty team list --json"))
        #expect(!skill.lowercased().contains("coworker"))
        #expect(!skill.contains("graftty team register"))
    }

    @Test("@spec TEAM-4.4: The Graftty Team provider skill shall instruct agents to send direct and broadcast message bodies through standard input with a quoted, freshly generated heredoc delimiter that is absent from the message, never as a shell argument, so shell syntax in messages remains literal.")
    func teamSkillDocumentsLiteralMessageInput() throws {
        let skill = try GrafttyTeamSkillText.load()

        #expect(skill.contains("graftty team send --stdin"))
        #expect(skill.contains("graftty team broadcast --stdin"))
        #expect(skill.contains("<graftty-peer-message agent=\"<exact-address>\" fallback-agent=\"<runtime-address>\">"))
        #expect(skill.contains("<graftty-forge-message provider=\"<provider>\">"))
        #expect(skill.contains("<graftty-system-message>"))
        #expect(skill.contains("stable reply address"))
        #expect(skill.contains("fresh quoted high-entropy heredoc delimiter"))
        #expect(skill.contains("does not occur in the body"))
        #expect(skill.contains("never as shell arguments"))
        #expect(!skill.contains("graftty team msg"))
    }

    @Test("Both runtimes produce the identical SessionStart context.")
    func bothRuntimesAlign() throws {
        let claude = try TeamHookRenderer.sessionStart(runtime: .claude, instructions: "X")
        let codex = try TeamHookRenderer.sessionStart(runtime: .codex, instructions: "X")
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

    @Test("A normal worktree message includes a reply command, canonical attribution, and no event template.")
    func formatWorktreeMessage() {
        let msg = message(
            id: "opaque-id",
            priority: .normal,
            body: "Please check the parser.",
            agentPrompt: "A Graftty automated team event was just delivered to you."
        )

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered.hasSuffix("""
        <graftty-peer-message agent="/repo/acme" fallback-agent="/repo/acme#claude">
        Please check the parser.
        </graftty-peer-message>
        """))
        #expect(rendered.contains("graftty team reply 'opaque-id' --stdin"))
        #expect(!rendered.contains("runtime="))
        #expect(!rendered.contains("automated team event"))
    }

    @Test("An urgent worktree message carries an explicit urgency marker so the post-tool-use preamble's urgent carve-out can fire.")
    func formatUrgentWorktreeMessage() {
        let msg = message(id: "m1", priority: .urgent, body: "This blocks the merge.")

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered.hasSuffix("""
        <graftty-peer-message agent="/repo/acme" fallback-agent="/repo/acme#claude" priority="urgent">
        This blocks the merge.
        </graftty-peer-message>
        """))
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
