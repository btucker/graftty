import Foundation

public enum TeamHookRenderer {
    public static func sessionStart(
        runtime: TeamHookRuntime,
        teamContext: String,
        instructions: String = "",
        messages: [TeamInboxMessage] = []
    ) throws -> String {
        switch runtime {
        case .codex:
            return try codexSessionStart(
                teamContext: teamContext,
                instructions: instructions,
                messages: messages
            )
        case .claude:
            return try claudeSessionStart(
                teamContext: teamContext,
                instructions: instructions,
                messages: messages
            )
        }
    }

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

    public static func codexSessionStart(
        teamContext: String,
        instructions: String = "",
        messages: [TeamInboxMessage] = []
    ) throws -> String {
        var sections: [String] = []
        if !teamContext.isEmpty { sections.append(teamContext) }
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

    public static func claudePostToolUse(messages: [TeamInboxMessage]) throws -> String {
        guard !messages.isEmpty else { return "{}" }
        let context = """
        Graftty team inbox update, unrelated to the tool result.

        Unless a message is explicitly urgent or directly blocks your current task, continue your current work using the tool result you just received.

        \(format(messages: messages))
        """
        return try hookJSON(eventName: "PostToolUse", additionalContext: context)
    }

    public static func claudeSessionStart(
        teamContext: String,
        instructions: String = "",
        messages: [TeamInboxMessage] = []
    ) throws -> String {
        try codexSessionStart(
            teamContext: teamContext,
            instructions: instructions,
            messages: messages
        )
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
