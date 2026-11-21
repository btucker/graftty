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

    static let skillGuidance = "Load the `graftty` skill for context updates. Read retained context with `graftty context show --json` at session start or after losing context. Send only changed groups with `graftty context update --stdin`. Initialize `purpose` with the stable title and the problem and why it matters, plus `now` with current progress and optional next step. Retain unchanged decisions and identity. Send a task-specific `emoji` and optional `emojiAlternatives` initially, and an `icon` with `iconDescription` once the task is clear or when a redraw is requested. Vary the composition and use the skill's palette tokens. Append `historyEntry` for meaningful changes and omit routine updates from history. Explicit attention is an ask requiring an answer or a notice worth reviewing. Routine progress stays quiet. Load the `graftty-team` skill for agent coordination and durable roles when you need to message, delegate, or pin an agent. Graftty keeps one implementer per worktree: never create a worktree yourself with `git worktree add`, a provider worktree tool, a worktree-isolated subagent, or another skill. To do work in a new worktree, delegate it with `graftty agent add <name> --provider <codex|claude> --prompt-stdin` as the `graftty-team` skill describes. To add a reviewer or pair to an existing worktree, use `graftty agent add <name> --worktree <worktree> --provider <codex|claude> --prompt-stdin`; an added agent does not edit files unless the implementer hands off. Harness-native subagents remain available within the session. Keep the primary agent of each worktree open for ongoing work, including in delegated worktrees. Only additional agents added by CLI agent-launch commands to an existing worktree finish bounded assignments with graftty agent finish --result-stdin. The parent of a bounded assignment must handle the result and run the exact graftty agent close --completion command in the completion event. UI-launched, observed, resumed, and unknown-origin sessions stay open for ongoing work."
        + " When a visual would explain something better, create self-contained HTML and deliver it with the `graftty-preview` skill. Use this skill when asked to show files or when producing a finished visual for review. Run `graftty preview` before responding; tool images, Markdown embeds, and file links alone do not open Graftty's native preview. Use `graftty-open` for requested URLs or an explicit request to open a file in its default app."
        + " " + recapGuidance

    static let codexSocketGuidance = "In Codex with restricted network access, request narrowly scoped permission with `sandbox_permissions: \"require_escalated\"` before the first control-socket command, including `graftty team list --json`. Use the same execution mode for subsequent control-socket commands; scope each request to the authorized command. Do not repeat a known sandbox denial. Do not change provider sandbox configuration to grant access. `graftty attention report --stdin`, `graftty context update --stdin`, and `graftty context show --json` use a private file handoff that does not need socket permission."

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

    /// Both providers accept UserPromptSubmit context before the ordinary
    /// turn. Stop cannot silently ask the main agent to execute another tool.
    /// Turn start asks for a pending redraw and lists nearby drawings
    /// while this worktree needs a drawing (AGENT-3.44, AGENT-3.46, AGENT-3.47).
    public static func userPromptSubmit(assignmentContext: String = "", drawingRedraw: WorktreeDrawing.Redraw? = nil,
                                        drawingThemeContext: String? = nil,
                                        drawingsInUse: [String] = []) throws -> String {
        let redrawRequest = switch drawingRedraw {
        case .widen: " This worktree's `icon` still uses the older square canvas. Redraw it once on the wide canvas, `<svg viewBox='0 0 96 64'>`, and include it in this turn's report. Graftty accepts it without resending `purpose`."
        case .varyComposition: " This worktree's `icon` predates the varied drawing guidance. Draw it once with a new composition and a distinct silhouette on the wide canvas, `<svg viewBox='0 0 96 64'>`. Include it and its `iconDescription` in this turn's report. Graftty accepts it without resending `purpose`."
        case .first: " This worktree has no `icon` yet. Draw one on the wide canvas, `<svg viewBox='0 0 96 64'>`, and include it and its `iconDescription` in this turn's report. Graftty accepts it without resending `purpose`."
        case nil: ""
        }
        return try hookJSON(eventName: "UserPromptSubmit", additionalContext: recapGuidance
            + redrawRequest
            + (drawingThemeContext.map {
                "\n\nThe active Ghostty theme has these resolved colors. Use them as a contrast reference for the worktree drawing at sidebar size. Paint the drawing with SVG palette tokens.\n\($0)\n"
            } ?? "")
            + (drawingsInUse.isEmpty ? "" : " Drawings already used in this project: "
                + drawingsInUse.joined(separator: "; ") + ". Draw a different subject and composition with a distinct silhouette.")
            + (assignmentContext.isEmpty ? "" : "\n\n" + assignmentContext))
    }

    static let recapGuidance = "During this turn, load the `graftty` skill and run `graftty context update --stdin` before your final response. Send changed groups only, or {\"unchanged\":true}. On first use send purpose, now, and emoji; send an `icon` once the purpose is clear or when a redraw is requested. Write `now.summary` in one plain sentence and keep `historyEntry` headlines short. Use attention.kind ask for input and include `background` needed to answer. For clear choices, give `options` with a few words of cost each and your suggested pick. Use notice for a reviewable result; routine progress updates Context only. Do not mention the report unless it fails. Do not acknowledge routine team notifications."

    /// Only a missing report reaches this fallback. `stop_hook_active` lets
    /// the correction turn finish even if the report command fails again.
    public static func requestRecap() -> String {
        let payload = [
            "decision": "block",
            "reason": "This turn has no Graftty context update. Load the `graftty` skill and run `graftty context update --stdin` now. Send only changed groups, or unchanged: true by itself if the retained context is current. Initialize purpose and now on first use. Do not repeat your answer or acknowledge the update. If reporting fails, finish; Stop will not ask again during this correction turn."
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
