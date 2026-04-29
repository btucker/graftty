import Foundation

/// Default Stencil templates for the two user-editable Agent Teams prompts
/// (TEAM-1.6). Registered into `UserDefaults.standard` at app startup so every
/// reader — `@AppStorage` bindings, `ChannelSettingsObserver`, and the
/// per-event `EventBodyRenderer` — sees the same default until the user
/// overrides it. Clearing a field to the empty string disables that prompt
/// (consumers treat empty as "no prompt").
enum DefaultPrompts {

    /// Rendered once at session start and appended to the auto-generated
    /// team-aware MCP instructions. Only `agent.branch` and `agent.lead` are
    /// meaningful at session start; the event-scoped fields exist in context
    /// but are always `false`, so the default deliberately doesn't reference
    /// them.
    static let sessionPrompt: String = """
    You are an agent in a Graftty team on branch `{{ agent.branch }}`.

    {% if agent.lead %}You are the team's lead — coordinate the other worktrees in this repo and surface their state to the user.{% else %}You are a coworker — focus on your branch's work and react to channel events from the team lead.{% endif %}
    """

    /// Rendered fresh for each channel-event delivery and prepended to the
    /// event body. Branches on `agent.this_worktree` / `agent.other_worktree`
    /// so the agent knows whether the event concerns its own branch.
    static let eventPrompt: String = """
    A Graftty team channel event was just delivered to you.

    {% if agent.this_worktree %}This event is about your own worktree.{% elif agent.other_worktree %}This event is about a different worktree in your team — only react if it changes how you should proceed.{% endif %}
    """

    /// Map suitable for `UserDefaults.standard.register(defaults:)`.
    static let registrations: [String: Any] = [
        SettingsKeys.teamSessionPrompt: sessionPrompt,
        SettingsKeys.teamPrompt: eventPrompt,
    ]
}
