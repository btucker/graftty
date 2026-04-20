import Foundation

/// Re-schedules `Attention`'s auto-clear timer after app launch.
///
/// The live timer is a `DispatchQueue.main.asyncAfter` scheduled when the
/// attention is first set — in-memory only, lost on force-quit. Without
/// a restart-time resume, an attention with a `clearAfter` (e.g. `espalier
/// notify "…" --clear-after 60`) that survived a crash mid-window stuck in
/// the sidebar until the user manually cleared it (`STATE-2.4`). Matches
/// Andy's "rage-quits if the attention badge doesn't clear" pain point
/// with a force-quit in the middle.
///
/// This helper is the pure decision: given a persisted `Attention` and
/// the current time, how many seconds of the original auto-clear window
/// remain? Caller schedules an `asyncAfter` for that duration.
public enum AttentionResumePolicy {

    /// Returns the remaining seconds to schedule the auto-clear timer
    /// against, or nil when no timer should be scheduled (the attention
    /// was persisted without a `clearAfter`).
    ///
    /// - Already-elapsed or exactly-at-deadline → `0` (caller schedules
    ///   a zero-delay asyncAfter which fires on the next main-queue turn
    ///   and clears the stale attention immediately).
    /// - Future-timestamp edge case (clock skew, hand-edit) → clamp to
    ///   the full `clearAfter` window measured from now.
    public static func remainingTime(for attention: Attention, now: Date) -> TimeInterval? {
        guard let clearAfter = attention.clearAfter else { return nil }
        let elapsed = now.timeIntervalSince(attention.timestamp)
        if elapsed < 0 {
            // Timestamp is in the future — treat as a fresh window.
            return clearAfter
        }
        if elapsed >= clearAfter { return 0 }
        return clearAfter - elapsed
    }
}
