import Foundation
import GrafttyKit

extension WorktreeEntry {
    /// The pane graftty considers "primary" for this worktree: the focused
    /// pane if one is set, otherwise the first leaf in the split tree.
    /// Used by the idle-delivery pipeline to route nudges to the agent's
    /// pane and by focus / split commands that need a single target.
    var firstPane: PaneSlotID? {
        focusedTerminalID ?? splitTree.allLeaves.first
    }
}
