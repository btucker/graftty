import Foundation
import GrafttyKit

/// Default Stencil template for the user-editable Agent Teams per-event
/// prompt. Registered into `UserDefaults.standard` at app startup so every
/// reader sees the same default until the user overrides it. Clearing the field
/// to the empty string disables the prompt (consumers treat empty as "no
/// prompt"). Agents are otherwise customized through `GRAFTTY.md` files.
enum DefaultPrompts {
    /// Rendered fresh for each automated event delivery. The event body already
    /// carries its scope and transition, so the default adds only guidance that
    /// can change what the recipient should do.
    static let eventPrompt: String = """
    {{ body }}
    {% if event.type == "merge_state_changed" -%}

    If the branch no longer merges cleanly, merge the default branch and resolve conflicts.
    {%- elif event.type == "ci_conclusion_changed" and event.attrs.to == "failure" -%}

    Investigate the failed checks and push a fix.
    {%- endif %}
    """

    /// Map suitable for `UserDefaults.standard.register(defaults:)`.
    static let registrations: [String: Any] = [
        SettingsKeys.teamPrompt: eventPrompt,
    ]

    /// `@AppStorage` does not reliably refresh when a value is removed behind
    /// its binding. Assign first so the editor updates immediately, then
    /// remove the persisted copy so future registered defaults can change.
    static func restoreEventPrompt(
        in defaults: UserDefaults = .standard,
        updateEditor: (String) -> Void
    ) {
        updateEditor(eventPrompt)
        defaults.removeObject(forKey: SettingsKeys.teamPrompt)
    }
}
