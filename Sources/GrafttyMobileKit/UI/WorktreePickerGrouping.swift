#if canImport(UIKit)
import GrafttyProtocol

/// Pure grouping helper for `WorktreePickerView`. Extracted from the
/// SwiftUI body so the order-preservation contract (IOS-9.9) can be
/// unit-tested without instantiating any view.
public enum WorktreePickerGrouping {

    /// Group `list` by `repoDisplayName`, preserving each key's
    /// first-occurrence order. This matches the order
    /// `GET /worktrees/panes` ships entries in, which mirrors the Mac
    /// sidebar's `appState.repos` ordering — so the mobile picker
    /// looks "the same" as the desktop sidebar.
    public static func grouped(_ list: [WorktreePanes]) -> [(String, [WorktreePanes])] {
        var order: [String] = []
        var groups: [String: [WorktreePanes]] = [:]
        for wt in list {
            if groups[wt.repoDisplayName] == nil { order.append(wt.repoDisplayName) }
            groups[wt.repoDisplayName, default: []].append(wt)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// Trailing destructive action surfaced on swipe. Nil for rows that
/// cannot be removed via the picker (main checkout, `.creating`).
public enum WorktreePickerSwipeAction: Equatable {
    case delete    // non-stale, non-main rows: runs `git worktree remove`
    case dismiss   // `.stale` rows: prunes the orphan admin entry

    public var buttonLabel: String {
        switch self {
        case .delete: return "Delete"
        case .dismiss: return "Dismiss"
        }
    }

    public var dialogTitle: String {
        switch self {
        case .delete: return "Delete Worktree?"
        case .dismiss: return "Dismiss Worktree?"
        }
    }

    public var dialogBody: String {
        switch self {
        case .delete: return "This will delete the worktree but not the branch."
        case .dismiss: return "This will remove this stale entry from Graftty."
        }
    }
}

extension WorktreePickerGrouping {
    /// IOS-9.6 rule: main checkout and in-flight rows have no swipe
    /// affordance — the first can't be deleted; the latter are
    /// mid-flight on the server. `.stale` rows offer Dismiss;
    /// everything else offers Delete.
    public static func swipeAction(for wt: WorktreePanes) -> WorktreePickerSwipeAction? {
        if wt.isMainCheckout { return nil }
        if wt.state.isInFlight { return nil }
        if wt.state == .stale { return .dismiss }
        return .delete
    }
}
#endif
