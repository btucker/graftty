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
///   - channelsEnabled: When true AND `defaultCommand` begins with the
///     `claude` binary name, the channel launch flags are inserted
///     between the binary and any user-supplied arguments. Otherwise
///     the command is returned unchanged.
public func defaultCommandDecision(
    defaultCommand: String,
    firstPaneOnly: Bool,
    isFirstPane: Bool,
    wasRehydrated: Bool,
    channelsEnabled: Bool = false
) -> DefaultCommandDecision {
    let trimmed = defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .skip }
    if wasRehydrated { return .skip }
    if firstPaneOnly && !isFirstPane { return .skip }

    let composed = composeWithChannelFlags(command: trimmed, channelsEnabled: channelsEnabled)
    return .type(composed)
}

/// Inserts channel launch flags between the `claude` binary name and any
/// user-supplied args when channels are enabled and the command begins
/// with `claude` as a whole token (not "claudex" etc.).
internal func composeWithChannelFlags(command: String, channelsEnabled: Bool) -> String {
    guard channelsEnabled else { return command }
    // Token-match on the first whitespace-delimited piece.
    let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard let binary = parts.first, binary == "claude" else { return command }
    let flags = "--channels plugin:graftty-channel --dangerously-load-development-channels plugin:graftty-channel"
    if parts.count == 1 {
        return "claude \(flags)"
    } else {
        return "claude \(flags) \(parts[1])"
    }
}
