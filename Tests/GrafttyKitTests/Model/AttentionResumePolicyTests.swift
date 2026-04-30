import Foundation
import Testing
@testable import GrafttyKit

/// `STATE-2.12` (new): when an `Attention` with a `clearAfter` survives an
/// app restart (persisted in state.json), the auto-clear timer must be
/// re-scheduled from the remaining time relative to `attention.timestamp`
/// — not left dangling as it is today. Prior to this policy, a force-quit
/// during a `--clear-after` window caused the badge to stick permanently
/// until the user manually clicked the worktree (STATE-2.4). Andy's
/// "rage-quits if the attention badge doesn't clear when he focuses the
/// worktree" pain point, but with a force-quit in the way.
@Suite("""
AttentionResumePolicy — restart-time timer scheduling

@spec STATE-2.12: When the application launches and loads persisted `Attention` entries (worktree-level `wt.attention` or pane-level `wt.paneAttention[terminalID]`), for each one that carries a non-nil `clearAfter`, the application shall reschedule the auto-clear timer against the remaining time derived from `attention.timestamp + clearAfter` relative to the current clock. If the deadline has already passed, the timer shall fire on the next main-queue turn (zero-delay `asyncAfter`) and clear the stale entry immediately. Without this resume, a force-quit during a `--clear-after` window leaves the attention stuck in state.json forever because the original `DispatchQueue.main.asyncAfter` is in-memory only. For defensive handling of a persisted timestamp in the future (clock skew, hand-edit), the remaining window shall be clamped to the full `clearAfter` duration measured from now rather than a negative elapsed value.
""")
struct AttentionResumePolicyTests {

    @Test func noTimerForAttentionWithoutClearAfter() {
        let att = Attention(text: "persistent", timestamp: Date(), clearAfter: nil)
        #expect(AttentionResumePolicy.remainingTime(for: att, now: Date()) == nil)
    }

    @Test func scheduleRemainingTimeWhenStillPending() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let stamp = Date(timeIntervalSinceReferenceDate: 999_990)  // 10s ago
        let att = Attention(text: "ping", timestamp: stamp, clearAfter: 30)
        let remaining = AttentionResumePolicy.remainingTime(for: att, now: now)
        #expect(remaining == 20)
    }

    @Test func expireImmediatelyWhenAlreadyElapsed() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let stamp = Date(timeIntervalSinceReferenceDate: 999_900)  // 100s ago
        let att = Attention(text: "old", timestamp: stamp, clearAfter: 30)
        // Elapsed (100s) > clearAfter (30s). `remainingTime` returns 0 —
        // caller schedules a zero-delay `asyncAfter` which fires on the
        // next main-queue turn and clears the stale attention.
        let remaining = AttentionResumePolicy.remainingTime(for: att, now: now)
        #expect(remaining == 0)
    }

    @Test func zeroRemainingAtExactDeadline() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_030)
        let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let att = Attention(text: "edge", timestamp: stamp, clearAfter: 30)
        // Elapsed (30s) == clearAfter (30s). Treat as already-expired.
        #expect(AttentionResumePolicy.remainingTime(for: att, now: now) == 0)
    }

    @Test func futureTimestampClampsToFullClearAfter() {
        // Defense against a state.json whose timestamp is somehow in the
        // future (clock skew, manual edit). Don't return negative remaining;
        // reset to the full clearAfter window from "now".
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let stamp = Date(timeIntervalSinceReferenceDate: 1_000_100)  // 100s ahead
        let att = Attention(text: "future", timestamp: stamp, clearAfter: 30)
        let remaining = AttentionResumePolicy.remainingTime(for: att, now: now)
        #expect(remaining == 30)
    }
}
