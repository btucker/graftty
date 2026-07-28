import Foundation
import GrafttyKit

extension WorktreeEntry {
    /// The best pane to target for focus/navigation: the focused pane when
    /// it still belongs to the split tree, otherwise the first leaf.
    /// Startup ownership is tracked separately by `primaryPaneSlotID`.
    var firstPane: PaneSlotID? {
        if let focusedPaneSlotID,
           splitTree.containsLeaf(focusedPaneSlotID) {
            return focusedPaneSlotID
        }
        return splitTree.allLeaves.first
    }

    /// Repair a stale persisted focus while preserving nil as "no explicit
    /// focus yet." Returns the same validated target as `firstPane`.
    @discardableResult
    mutating func normalizeFocusedPane() -> PaneSlotID? {
        let primaryPane = firstPane
        if focusedPaneSlotID != nil, focusedPaneSlotID != primaryPane {
            focusedPaneSlotID = primaryPane
        }
        return primaryPane
    }
}
