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
#endif
