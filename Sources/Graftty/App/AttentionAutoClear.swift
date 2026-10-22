import Foundation
import GrafttyKit
import SwiftUI

/// Clears a timed attention once its `clearAfter` elapses. The stamp is
/// the attention's timestamp, so a newer ping or an explicit clear that
/// lands before the timer fires is left alone.
@MainActor
enum AttentionAutoClear {
    /// Clears the worktree-scoped attention at `worktreePath`, or the
    /// attention of `pane` within it, after `delay` seconds.
    static func schedule(
        after delay: TimeInterval,
        appState: Binding<AppState>,
        worktreePath: String,
        pane: PaneSlotID? = nil,
        stamp: Date
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            appState.wrappedValue.mutateWorktrees(atPath: worktreePath) { worktree in
                if let pane {
                    worktree.clearPaneAttentionIfTimestamp(stamp, for: pane)
                } else {
                    worktree.clearAttentionIfTimestamp(stamp)
                }
            }
        }
    }
}
