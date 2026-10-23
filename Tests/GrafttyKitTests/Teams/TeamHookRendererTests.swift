import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamHookRenderer")
struct TeamHookRendererTests {
    @Test("@spec PREVIEW-3.1: When an agent session starts, the application shall instruct agents to explain visually useful material with self-contained HTML and deliver it through graftty preview.")
    func asksForHTMLExplanations() throws {
        for runtime in [TeamHookRuntime.codex, .claude] {
            let context = try additionalContext(from: TeamHookRenderer.sessionStart(runtime: runtime))
            #expect(context.contains("self-contained HTML"))
            #expect(context.contains("Run `graftty preview` before responding"))
            #expect(context.contains("`graftty-preview` skill"))
        }
    }

    @Test("@spec AGENT-6.53: When a Codex session starts, the application shall instruct the agent to request narrowly scoped elevated permission before its first main control-socket command in a restricted sandbox, retain that choice for subsequent commands, and keep Attention file reports unprivileged.")
    func codexSessionExplainsSocketPermissionBeforeFirstCommand() throws {
        let context = try additionalContext(from: TeamHookRenderer.sessionStart(runtime: .codex))
        #expect(context.contains("before the first control-socket command"))
        #expect(context.contains("require_escalated"))
        #expect(context.contains("subsequent control-socket commands"))
        #expect(context.contains("graftty attention report"))
        #expect(context.contains("does not need socket permission"))
        let claude = try additionalContext(from: TeamHookRenderer.sessionStart(runtime: .claude))
        #expect(!claude.contains("require_escalated"))
    }

    @Test("@spec AGENT-6.33: When an agent session starts, the application shall instruct the agent to load Graftty skills for Attention recaps, coordination and durable roles, and native previews of requested or completed review artifacts, and require a task-specific emoji independently of cached skill instructions.")
    func managedSessionLoadsGrafttySkill() throws {
        for runtime in [TeamHookRuntime.codex, .claude] {
            let json = try TeamHookRenderer.sessionStart(runtime: runtime)
            let context = try additionalContext(from: json)
            #expect(context.contains("Load the `graftty` skill for Attention recaps"))
            #expect(context.contains("`graftty-team` skill for agent coordination"))
            #expect(context.contains("durable roles"))
            #expect(context.contains("task-specific `emoji`"))
            #expect(context.contains("`historyEntry`"))
            #expect(context.contains("omit routine updates"))
            #expect(context.contains("`emojiAlternatives`"))
            #expect(context.contains("`graftty-preview` skill"))
            #expect(context.contains("asked to show files"))
            #expect(context.contains("finished visual for review"))
            #expect(context.contains("Run `graftty preview` before responding"))
            #expect(context.contains("`graftty-open`"))
            #expect(context.contains("requested URLs"))
        }
    }

    @Test("@spec AGENT-6.44: When an agent session starts, the application shall instruct the agent to keep one implementer per worktree by never creating a worktree itself, including through git, provider worktree tools, or other skills, to delegate new-worktree work with graftty worktree add and an agent, and to add a reviewer or pair to an existing worktree with graftty pane add and an agent that does not edit files unless the implementer hands off.")
    func managedSessionForbidsManualWorktrees() throws {
        for runtime in [TeamHookRuntime.codex, .claude] {
            let json = try TeamHookRenderer.sessionStart(runtime: runtime)
            let context = try additionalContext(from: json)
            #expect(context.contains("one implementer per worktree"))
            #expect(!context.contains("one agent per worktree"))
            #expect(context.contains("`git worktree add`"))
            #expect(context.contains("`graftty worktree add <name> --agent"))
            #expect(context.contains("`graftty pane add <worktree> --agent <codex|claude> --prompt-stdin`"))
            #expect(context.contains("unless the implementer hands off"))
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
        #expect(json["reason"]?.contains("historyEntry") == true)
        #expect(json["reason"]?.contains("Omit historyEntry for routine updates") == true)
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
        #expect(context.contains("<graftty-peer-message agent=\"/repo/acme\" fallback-agent=\"/repo/acme#claude\" id=\"m1\" priority=\"urgent\">"))
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
        #expect(skill.contains("graftty team broadcast --stdin"))
        let example = try #require(skill.components(separatedBy: "```sh\n").dropFirst().first)
            .components(separatedBy: "```")[0]
        let lines = example.split(separator: "\n")
        let command = try #require(lines.first)
        let delimiter = try #require(lines.last)
        let payload = "literal ${GRAFTTY_TEST_LITERAL} $(printf expanded) `printf expanded`"
        let script = "graftty() { printf '%s\\n' \"$@\"; cat; }\n\(command)\n\(payload)\n\(delimiter)\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/bin:/bin", "GRAFTTY_TEST_LITERAL": "expanded"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text == "team\nsend\n--stdin\n<address>\n\(payload)\n")
    }

    @Test("Both runtimes preserve shared SessionStart context around Codex socket guidance.")
    func bothRuntimesPreserveSharedContext() throws {
        let claude = try additionalContext(from: TeamHookRenderer.sessionStart(runtime: .claude, instructions: "X"))
        let codex = try additionalContext(from: TeamHookRenderer.sessionStart(runtime: .codex, instructions: "X"))
        #expect(claude == TeamHookRenderer.skillGuidance + "\n\n\nX")
        #expect(codex == TeamHookRenderer.skillGuidance + "\n\n\n" + TeamHookRenderer.codexSocketGuidance + "\n\n\nX")
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

    @Test("A normal worktree message includes reply metadata, canonical attribution, and no event template.")
    func formatWorktreeMessage() {
        let msg = message(
            id: "opaque-id",
            priority: .normal,
            body: "Please check the parser.",
            agentPrompt: "A Graftty automated team event was just delivered to you."
        )

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered == """
        <graftty-peer-message agent="/repo/acme" fallback-agent="/repo/acme#claude" id="opaque-id">
        Please check the parser.
        </graftty-peer-message>
        """)
        #expect(!rendered.contains("runtime="))
        #expect(!rendered.contains("automated team event"))
    }

    @Test("An urgent worktree message carries an explicit urgency marker so the post-tool-use preamble's urgent carve-out can fire.")
    func formatUrgentWorktreeMessage() {
        let msg = message(id: "m1", priority: .urgent, body: "This blocks the merge.")

        let rendered = TeamHookRenderer.format(messages: [msg])

        #expect(rendered.hasSuffix("""
        <graftty-peer-message agent="/repo/acme" fallback-agent="/repo/acme#claude" id="m1" priority="urgent">
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
