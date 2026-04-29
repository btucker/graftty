import Testing
@testable import GrafttyKit

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

    @Test func onlyCIPendingTonePulses() {
        #expect(PRBadgeStyle.Tone.ciPending.pulses == true)
        #expect(PRBadgeStyle.Tone.ciFailure.pulses == false)
        #expect(PRBadgeStyle.Tone.open.pulses == false)
        #expect(PRBadgeStyle.Tone.merged.pulses == false)
    }
}
