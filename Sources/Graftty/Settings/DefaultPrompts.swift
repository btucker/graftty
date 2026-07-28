import Foundation
import GrafttyKit

/// Default Stencil templates for the two user-editable Agent Teams prompts.
/// Registered into `UserDefaults.standard` at app startup so every reader sees
/// the same default until the user overrides it. Clearing a field to the empty
/// string disables that prompt (consumers treat empty as "no prompt").
enum DefaultPrompts {
    /// The complete SessionStart hook prompt. Dynamic identity and roster data
    /// remain visible as Stencil placeholders in Settings, then resolve when
    /// each session starts.
    static let sessionPrompt = TeamInstructionsRenderer.defaultTemplate

    /// Rendered fresh for each automated event delivery and prepended to the
    /// event body. Branches on `agent.this_worktree` / `agent.other_worktree`
    /// so the agent knows whether the event concerns its own branch, then
    /// branches on `event.type` for event-specific guidance — Stencil has no
    /// `case` tag, so the "switch on event.type" is expressed as a chained
    /// `{% if event.type == "…" %} … {% elif … %} …` block.
    static let eventPrompt: String = """
    A Graftty automated team event was just delivered to you.

    {% if agent.this_worktree -%}
    This event is about your own worktree.
    {%- elif agent.other_worktree -%}
    This event is about a different worktree in your team — only react if it changes how you should proceed.
    {%- endif %}

    {% if event.type == "merge_state_changed" -%}
    Your branch's mergeability against the default branch changed. If your branch can no longer merge cleanly, merge the default branch into your branch and resolve any conflicts before continuing.
    {%- elif event.type == "pr_state_changed" -%}
    A PR's state changed. If it concerns your branch, react to the new state.
    {%- elif event.type == "ci_conclusion_changed" -%}
    A PR's CI conclusion changed. If it concerns your branch and CI is failing, investigate the failures and push fixes.
    {%- endif %}
    """

    /// Map suitable for `UserDefaults.standard.register(defaults:)`.
    static let registrations: [String: Any] = [
        SettingsKeys.teamSessionPrompt: sessionPrompt,
        SettingsKeys.teamPrompt: eventPrompt,
    ]

    /// Validate a complete session template against the same object shapes the
    /// SessionStart renderer supplies. Exercise both role branches and
    /// non-empty roster loops so a failure hidden in linked-worktree-only
    /// content cannot invalidate that viewer's complete prompt after upgrade.
    /// The built-in prefix guarantees a successful render is non-empty, so
    /// `nil` unambiguously means that the candidate cannot render.
    static func isRenderableSessionPrompt(_ template: String) -> Bool {
        let mainWorktree: [String: Any] = [
            "name": "main",
            "worktree": "/repo",
            "branch": "main",
            "main_worktree": true,
            "running": true,
        ]
        let linkedWorktree: [String: Any] = [
            "name": "feature",
            "worktree": "/repo/.worktrees/feature",
            "branch": "feature",
            "main_worktree": false,
            "running": true,
        ]
        let peerWorktree: [String: Any] = [
            "name": "peer",
            "worktree": "/repo/.worktrees/peer",
            "branch": "peer",
            "main_worktree": false,
            "running": false,
        ]
        let members = [mainWorktree, linkedWorktree, peerWorktree]
        let baseTeam: [String: Any] = [
            "repo": "repo",
            "repo_path": "/repo",
            "main_worktree": mainWorktree,
            "members": members,
        ]
        let viewers: [(member: [String: Any], others: [[String: Any]])] = [
            (mainWorktree, [linkedWorktree, peerWorktree]),
            (linkedWorktree, [peerWorktree]),
            // A two-member team gives its sole linked viewer an empty
            // `team.other_worktrees`, which exercises Stencil's `{% empty %}`
            // loop branch.
            (linkedWorktree, []),
        ]
        return viewers.allSatisfy { viewer in
            let agent = viewer.member.merging([
                "this_worktree": false,
                "other_worktree": false,
            ]) { _, new in new }
            let team = baseTeam.merging([
                "other_worktrees": viewer.others,
            ]) { _, new in new }
            return EventBodyRenderer.renderAgentTemplate(
                template,
                agent: agent,
                additionalContext: ["team": team]
            ) != nil
        }
    }

    /// `@AppStorage` does not reliably refresh when a value is removed behind
    /// its binding. Assign first so the editor updates immediately, then
    /// remove the persisted copy so future registered defaults can change.
    static func restoreSessionPrompt(
        in defaults: UserDefaults = .standard,
        updateEditor: (String) -> Void
    ) {
        updateEditor(sessionPrompt)
        defaults.removeObject(forKey: SettingsKeys.teamSessionPrompt)
    }

    static func restoreEventPrompt(
        in defaults: UserDefaults = .standard,
        updateEditor: (String) -> Void
    ) {
        updateEditor(eventPrompt)
        defaults.removeObject(forKey: SettingsKeys.teamPrompt)
    }
}
