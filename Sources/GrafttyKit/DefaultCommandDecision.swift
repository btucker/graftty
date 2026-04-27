import Foundation

/// Decision about what to do when a pane's shell becomes ready.
public enum DefaultCommandDecision: Equatable, Sendable {
    case skip
    case type(String)
}

/// The command Graftty types into every pane when Agent Teams mode is on.
/// Kept as a single public constant so the UI (SettingsView, AgentTeamsSettingsPane)
/// and the runtime always display and launch exactly the same string.
public let teamModeManagedCommand =
    "claude --dangerously-load-development-channels server:graftty-channel"

/// Pure decision function for whether to auto-type the user's default
/// command into a freshly-ready pane. Extracted from the UI layer so it
/// can be exercised without a running NSApplication or libghostty surface.
///
/// - Parameters:
///   - defaultCommand: The user's configured command string (from
///     `@AppStorage("defaultCommand")`). Empty or whitespace-only disables
///     the feature.
///   - firstPaneOnly: Whether the command should only fire on the first
///     pane of a worktree. When `false`, fires on every pane.
///   - isFirstPane: Whether this specific pane is the first pane of its
///     worktree (i.e., the pane that caused `.closed → .running`).
///   - wasRehydrated: Whether this pane was recreated by the
///     restore-on-launch path. Rehydrated panes never auto-run — the
///     command is already presumed running under zmx.
///   - agentTeamsEnabled: When `true`, the user's `defaultCommand` is
///     ignored and `teamModeManagedCommand` is used instead (TEAM-1.4).
///     Defaults to `false` so existing call sites compile without changes.
public func defaultCommandDecision(
    defaultCommand: String,
    firstPaneOnly: Bool,
    isFirstPane: Bool,
    wasRehydrated: Bool,
    agentTeamsEnabled: Bool = false
) -> DefaultCommandDecision {
    if wasRehydrated { return .skip }
    if firstPaneOnly && !isFirstPane { return .skip }

    let resolved: String
    if agentTeamsEnabled {
        resolved = teamModeManagedCommand
    } else {
        let trimmed = defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .skip }
        resolved = trimmed
    }
    return .type(resolved)
}
