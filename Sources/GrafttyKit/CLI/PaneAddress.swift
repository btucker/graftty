import Foundation

/// Parsed form of the optional `<addr>` positional shared by every
/// `graftty pane *` subcommand.
///
/// Grammar (per `docs/superpowers/specs/2026-05-08-controlling-panes-design.md`):
///   omitted     → .currentWorktreeAnyPane
///   <id>        → .currentWorktreeID(id)
///   <name>      → .namedWorktreeAnyPane(name)
///   <name>:<id> → .namedWorktreeID(name, id)
public enum PaneAddress: Equatable, Sendable {
    case currentWorktreeAnyPane
    case currentWorktreeID(Int)
    case namedWorktreeAnyPane(String)
    case namedWorktreeID(String, Int)
    /// Couldn't parse — caller should print an error using the original
    /// raw string so the agent sees what was rejected.
    case invalid(String)

    public static func parse(_ raw: String?) -> PaneAddress {
        guard let raw, !raw.isEmpty else { return .currentWorktreeAnyPane }

        // Numeric-only → current worktree, that pane.
        if let id = Int(raw) {
            return id >= 1 ? .currentWorktreeID(id) : .invalid(raw)
        }

        // An absolute path can contain colons in any parent component. Only
        // the final colon is eligible for the optional pane suffix.
        if NSString(string: raw).isAbsolutePath {
            if let separator = raw.lastIndex(of: ":") {
                let name = String(raw[..<separator])
                let idString = String(raw[raw.index(after: separator)...])
                if !name.isEmpty, let id = Int(idString), id >= 1 {
                    return .namedWorktreeID(name, id)
                }
            }
            return .namedWorktreeAnyPane(raw)
        }

        // Otherwise: <name> or <name>:<id>.
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            // Bare name. Reject empty (caught by !raw.isEmpty above) and
            // anything that's actually numeric (caught by Int(raw) above).
            return .namedWorktreeAnyPane(String(parts[0]))
        case 2:
            let name = String(parts[0])
            let idStr = String(parts[1])
            guard !name.isEmpty, !idStr.isEmpty, let id = Int(idStr), id >= 1 else {
                return .invalid(raw)
            }
            return .namedWorktreeID(name, id)
        default:
            return .invalid(raw)
        }
    }
}
