import Testing
@testable import GrafttyProtocol

@Suite("PRBadgeStyle")
struct PRBadgeStyleTests {
    @Test func openWithSuccessUsesOpenTone() {
        #expect(PRBadgeStyle.tone(state: .open, checks: .success) == .open)
    }

    @Test func openWithNoChecksUsesOpenTone() {
        #expect(PRBadgeStyle.tone(state: .open, checks: .none) == .open)
    }

    @Test func openWithFailureUsesCIFailureTone() {
        #expect(PRBadgeStyle.tone(state: .open, checks: .failure) == .ciFailure)
    }

    @Test func openWithPendingUsesCIPendingTone() {
        #expect(PRBadgeStyle.tone(state: .open, checks: .pending) == .ciPending)
    }

    @Test func mergedAlwaysUsesMergedToneRegardlessOfChecks() {
        #expect(PRBadgeStyle.tone(state: .merged, checks: .success) == .merged)
        #expect(PRBadgeStyle.tone(state: .merged, checks: .failure) == .merged)
        #expect(PRBadgeStyle.tone(state: .merged, checks: .pending) == .merged)
        #expect(PRBadgeStyle.tone(state: .merged, checks: .none) == .merged)
    }

    @Test func closedAlwaysUsesClosedToneRegardlessOfChecks() {
        #expect(PRBadgeStyle.tone(state: .closed, checks: .success) == .closed)
        #expect(PRBadgeStyle.tone(state: .closed, checks: .failure) == .closed)
        #expect(PRBadgeStyle.tone(state: .closed, checks: .pending) == .closed)
        #expect(PRBadgeStyle.tone(state: .closed, checks: .none) == .closed)
    }

    @Test func onlyCIPendingTonePulses() {
        #expect(PRBadgeStyle.Tone.ciPending.pulses == true)
        #expect(PRBadgeStyle.Tone.ciFailure.pulses == false)
        #expect(PRBadgeStyle.Tone.open.pulses == false)
        #expect(PRBadgeStyle.Tone.merged.pulses == false)
        #expect(PRBadgeStyle.Tone.closed.pulses == false)
        #expect(PRBadgeStyle.Tone.conflicting.pulses == false)
    }

    @Test("""
    @spec PR-8.20: When the application picks the sidebar `#<number>` badge tone for a worktree's PR, the priority shall be merged/closed > CI failure > CI pending > merge conflict > open. CI signals win over a merge conflict because they're tighter feedback on the user's current change; once CI is clean, the conflict tone surfaces and tells the user to rebase. Terminal states (`.merged` and `.closed`-without-merging) ignore CI entirely — CI on a dead PR is stale. The `.conflicting` tone gives "PR has conflicts but CI is green" a visually distinct signal from "PR is broken in CI".
    """)
    func openConflictingShowsConflictTone() {
        #expect(PRBadgeStyle.tone(state: .open, checks: .success, mergeable: .conflicting) == .conflicting)
        #expect(PRBadgeStyle.tone(state: .open, checks: .none, mergeable: .conflicting) == .conflicting)
    }

    @Test func ciFailureBeatsConflict() {
        // A failing CI run is more actionable than a merge
        // conflict; surface the failure first.
        #expect(PRBadgeStyle.tone(state: .open, checks: .failure, mergeable: .conflicting) == .ciFailure)
    }

    @Test func ciPendingBeatsConflict() {
        // CI is mid-run — wait to see how it lands before
        // surfacing the conflict.
        #expect(PRBadgeStyle.tone(state: .open, checks: .pending, mergeable: .conflicting) == .ciPending)
    }

    @Test func mergedIgnoresMergeable() {
        #expect(PRBadgeStyle.tone(state: .merged, checks: .none, mergeable: .conflicting) == .merged)
    }

    @Test func closedIgnoresMergeable() {
        #expect(PRBadgeStyle.tone(state: .closed, checks: .none, mergeable: .conflicting) == .closed)
    }

    @Test func mergeableMergeableOrUnknownStaysOpen() {
        #expect(PRBadgeStyle.tone(state: .open, checks: .success, mergeable: .mergeable) == .open)
        #expect(PRBadgeStyle.tone(state: .open, checks: .success, mergeable: .unknown) == .open)
    }
}
