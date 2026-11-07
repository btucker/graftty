import Testing
@testable import GrafttyRemoteClient

struct TerminalOutputPacingTests {
    private let maximum = 1024 * 1024

    @Test("@spec REMOTE-9.23: If adaptive terminal output pacing is explicitly enabled, then the client shall reduce credits for a slow consumer without acknowledging undelivered bytes or moving cumulative acknowledgements backward.")
    func slowConsumerWithholdsCreditWithinTheNegotiatedWindow() {
        var pacing = TerminalOutputPacing(windowBytes: maximum, adaptive: true)
        pacing.didDeliver(bytes: 256 * 1024, atNanoseconds: 0)
        pacing.consumerReady(atNanoseconds: 125_000_000)
        #expect(pacing.windowBytes == 128 * 1024)
        // The host has already received this acknowledgement. A smaller
        // target cannot retract it, so wait for the existing credit to drain.
        #expect(pacing.acknowledgement(consumed: UInt64(maximum), acknowledged: 256 * 1024) == nil)
        let next = pacing.acknowledgement(consumed: UInt64(2 * maximum), acknowledged: UInt64(maximum))
        #expect(next == UInt64(maximum + 128 * 1024))
    }

    @Test("@spec REMOTE-9.24: While adaptive terminal output pacing measures consumer speed, the client shall exclude time spent awaiting network output and restore available credit when the consumer speeds up.")
    func networkWaitDoesNotLookLikeSlowRendering() {
        var pacing = TerminalOutputPacing(windowBytes: maximum, adaptive: true)
        pacing.didDeliver(bytes: 256 * 1024, atNanoseconds: 0)
        pacing.consumerReady(atNanoseconds: 125_000_000)
        #expect(pacing.windowBytes < maximum)
        // A long wait before delivery is network time, not processing time.
        pacing.didDeliver(bytes: 64 * 1024, atNanoseconds: 10_000_000_000)
        pacing.consumerReady(atNanoseconds: 10_001_000_000)
        #expect(pacing.windowBytes == maximum)
        #expect(pacing.acknowledgement(consumed: UInt64(maximum), acknowledged: 128 * 1024) == UInt64(maximum))
    }

    @Test func fixedPolicyKeepsExistingAcknowledgements() {
        var pacing = TerminalOutputPacing(windowBytes: maximum, adaptive: false)
        pacing.didDeliver(bytes: 16 * 1024, atNanoseconds: 0)
        pacing.consumerReady(atNanoseconds: 1_000_000_000)
        #expect(pacing.windowBytes == maximum)
        #expect(pacing.acknowledgement(consumed: 128 * 1024, acknowledged: 0) == 128 * 1024)
        #expect(pacing.acknowledgement(consumed: 127 * 1024, acknowledged: 0) == nil)
    }

    @Test(arguments: [64, 128, 1024])
    func targetStaysWithinNegotiatedBounds(kibibytes: Int) {
        let maximum = kibibytes * 1024
        var pacing = TerminalOutputPacing(windowBytes: maximum, adaptive: true)
        pacing.didDeliver(bytes: 16 * 1024, atNanoseconds: 1)
        pacing.consumerReady(atNanoseconds: UInt64.max)
        #expect(pacing.windowBytes == min(maximum, 128 * 1024))
        pacing.didDeliver(bytes: 256 * 1024, atNanoseconds: 100)
        pacing.consumerReady(atNanoseconds: 101)
        #expect(pacing.windowBytes == maximum)
        #expect(pacing.acknowledgement(consumed: 0, acknowledged: 0) == nil)
        #expect(pacing.acknowledgement(consumed: 1, acknowledged: 2) == nil)
    }
}
