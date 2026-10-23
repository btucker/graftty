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
        // A main-actor Task rather than asyncAfter so the save below reaches
        // the same persister as the caller (task-locals carry into it). The
        // deadline is fixed now, as asyncAfter's was, because the task can
        // start late while the main actor is busy. A persisted `clearAfter`
        // past the STATE-2.9 cap is clamped so `Duration` cannot overflow.
        let deadline = ContinuousClock.now + .seconds(min(delay, Attention.clearAfterMaxSeconds))
        Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: .continuous)
            // Fires with or without a window open (#604).
            GrafttyApp.persistingChanges(to: appState) {
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
}
