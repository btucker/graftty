import Foundation

/// Default Stencil templates for the two user-editable Agent Teams prompts.
/// Registered into `UserDefaults.standard` at app startup so every reader sees
/// the same default until the user overrides it. Clearing a field to the empty
/// string disables that prompt (consumers treat empty as "no prompt").
enum DefaultPrompts {

    /// Rendered once at hook session start and appended to the auto-generated
    /// team-aware instructions. Only `agent.branch` and `agent.lead` are
    /// meaningful at session start, so the default deliberately does not
    /// reference event-scoped fields.
    static let sessionPrompt: String = """
    You are an agent in a Graftty team on branch `{{ agent.branch }}`.

    {% if agent.lead %}You are the team's lead — coordinate the other worktrees in this repo and surface their state to the user.{% else %}You are a coworker — focus on your branch's work and react to direct messages or automated team events only when they affect your current task.{% endif %}
    """

    /// Rendered fresh for each automated event delivery and prepended to the
    /// event body. Branches on `agent.this_worktree` / `agent.other_worktree`
    /// so the agent knows whether the event concerns its own branch.
    static let eventPrompt: String = """
    A Graftty automated team event was just delivered to you.

    {% if agent.this_worktree %}This event is about your own worktree.{% elif agent.other_worktree %}This event is about a different worktree in your team — only react if it changes how you should proceed.{% endif %}
    """

    /// Map suitable for `UserDefaults.standard.register(defaults:)`.
    static let registrations: [String: Any] = [
        SettingsKeys.teamSessionPrompt: sessionPrompt,
        SettingsKeys.teamPrompt: eventPrompt,
    ]
}
