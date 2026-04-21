import Foundation

/// Decision about what to do when a pane's shell becomes ready.
public enum DefaultCommandDecision: Equatable, Sendable {
    case skip
    case type(String)
}

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
public func defaultCommandDecision(
    defaultCommand: String,
    firstPaneOnly: Bool,
    isFirstPane: Bool,
    wasRehydrated: Bool
) -> DefaultCommandDecision {
    let trimmed = defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .skip }
    if wasRehydrated { return .skip }
    if firstPaneOnly && !isFirstPane { return .skip }
    return .type(trimmed)
}
