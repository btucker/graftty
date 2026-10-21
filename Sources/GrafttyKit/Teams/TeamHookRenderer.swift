import Foundation

public enum TeamHookRenderer {
    /// SessionStart context: a pointer to the provider plugin's Graftty
    /// skills, then the session's `GRAFTTY.md` instructions, then any inbox
    /// messages queued before the session started.
    public static func sessionStart(
        runtime: TeamHookRuntime,
        instructions: String = "",
        messages: [TeamInboxMessage] = []
    ) throws -> String {
        var sections = [skillGuidance]
        if runtime == .codex { sections.append(codexSocketGuidance) }
        if !instructions.isEmpty { sections.append(instructions) }
        if !messages.isEmpty {
            sections.append("""
            Worktree inbox messages queued before this process started:

            \(format(messages: messages))
            """)
        }
        let context = sections.joined(separator: "\n\n\n")
        return try hookJSON(eventName: "SessionStart", additionalContext: context)
    }

    static let skillGuidance = "Load the `graftty` skill for Attention recaps before finishing this session. Keep `title` stable as the worktree purpose; set `purposeChanged: true` only when that purpose changes. Keep the problem being solved and why it matters front and center: include that motivation in `context` on every recap, preserving it as work progresses and refining it as understanding improves. Put current progress in `completed` and remaining work in `next`. Include `decisions` as the complete current list of decisions worth retaining. Include a short `checkpoint` only for a meaningful milestone or decision; reuse the same checkpoint label while refining it. Each new recap must include a task-specific `emoji`; provide up to three distinct `emojiAlternatives` so Graftty can choose an unused identity. Include these fields even if an older cached skill omits them. Load the `graftty-team` skill for agent coordination and durable roles when you need to message, delegate, or pin an agent. Graftty keeps one implementer per worktree: never create a worktree yourself with `git worktree add`, a provider worktree tool, a worktree-isolated subagent, or another skill. To do work in a new worktree, delegate it with `graftty worktree add <name> --agent <codex|claude> --prompt-stdin` as the `graftty-team` skill describes. To add a reviewer or pair to an existing worktree, use `graftty pane add <worktree> --agent <codex|claude> --prompt-stdin`; an added agent does not edit files unless the implementer hands off."
        + " When a visual would explain something better, create self-contained HTML and deliver it with the `graftty-preview` skill. Use this skill when asked to show files or when producing a finished visual for review. Run `graftty preview` before responding; tool images, Markdown embeds, and file links alone do not open Graftty's native preview. Use `graftty-open` for requested URLs or an explicit request to open a file in its default app."

    static let codexSocketGuidance = "In Codex with restricted network access, request narrowly scoped permission with `sandbox_permissions: \"require_escalated\"` before the first control-socket command, including `graftty team list --json`. Use the same execution mode for subsequent control-socket commands; scope each request to the authorized command. Do not repeat a known sandbox denial. Do not change provider sandbox configuration to grant access. `graftty attention report --stdin` uses a private file handoff and does not need socket permission."

    public static func postToolUse(runtime: TeamHookRuntime, messages: [TeamInboxMessage]) throws -> String {
        switch runtime {
        case .codex:
            return "{}"
        case .claude:
            return try claudePostToolUse(messages: messages)
        }
    }

    public static func stop(runtime: TeamHookRuntime, messages: [TeamInboxMessage]) throws -> String {
        _ = runtime
        _ = messages
        return "{}"
    }

    public static func requestRecap() -> String {
        let payload = [
            "decision": "block",
            "reason": "Before finishing, load the Graftty skill if available and run `graftty attention report --stdin` with a brief JSON recap: title, context, completed, next, emoji, emojiAlternatives, and optional need, decisions, and checkpoint. Lead with the problem being solved and why it matters in context; preserve that motivation across progress updates. Keep title stable; set purposeChanged to true only when the worktree purpose changes. Put verified progress in completed and remaining work in next. Include need only when user input is required to continue. Include decisions as the complete current list, and checkpoint only for meaningful milestones. Include a task-specific `emoji` even if an older cached skill omits it; use `emojiAlternatives` for up to three distinct task-related alternatives. If you already reported without an emoji, resend the recap with these fields. Then finish your response. Do not mention the report in your response. If the command fails, say so in the response; Graftty will stop without asking again."
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func claudePostToolUse(messages: [TeamInboxMessage]) throws -> String {
        guard !messages.isEmpty else { return "{}" }
        let context = """
        Graftty team inbox update, unrelated to the tool result.

        Unless a message is explicitly urgent or directly blocks your current task, continue your current work using the tool result you just received.

        \(format(messages: messages))
        """
        return try hookJSON(eventName: "PostToolUse", additionalContext: context)
    }

    public static func format(messages: [TeamInboxMessage]) -> String {
        TeamPeerMessageFormatter.context(messages: messages)
    }

    static func content(message: TeamInboxMessage) -> String {
        if message.kind == TeamChannelEvents.EventType.message {
            return message.body
        }
        return message.agentPrompt ?? message.body
    }

    private static func hookJSON(eventName: String, additionalContext: String) throws -> String {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": eventName,
                "additionalContext": additionalContext,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

}
