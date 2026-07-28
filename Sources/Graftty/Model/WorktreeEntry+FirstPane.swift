import Foundation
import GrafttyKit

extension WorktreeEntry {
    /// The pane graftty considers "primary" for this worktree: the focused
    /// pane when it still belongs to the split tree, otherwise the first
    /// leaf. Persisted focus can be stale after state migration or repair.
    /// Used by focus / split commands that need a single target.
    var firstPane: PaneSlotID? {
        if let focusedPaneSlotID,
           splitTree.containsLeaf(focusedPaneSlotID) {
            return focusedPaneSlotID
        }
        return splitTree.allLeaves.first
    }

    /// Repair a stale persisted focus while preserving nil as "no explicit
    /// focus yet." Returns the same validated primary pane as `firstPane`.
    @discardableResult
    mutating func normalizeFocusedPane() -> PaneSlotID? {
        let primaryPane = firstPane
        if focusedPaneSlotID != nil, focusedPaneSlotID != primaryPane {
            focusedPaneSlotID = primaryPane
        }
        return primaryPane
    }
}
