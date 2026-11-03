import Foundation
import GrafttyRemoteTestSupport
import Testing

struct TransportLatencySummaryTests {
    @Test("@spec SSH-1.10: When a transport latency probe reports percentiles, the application shall include the sample count and nearest-rank p50, p95, p99, and maximum latency without retaining terminal contents.")
    func percentilesUseNearestRank() throws {
        let summary = try #require(TransportLatencySummary(milliseconds: (1...100).reversed().map(Double.init)))
        #expect(summary.sampleCount == 100)
        #expect(summary.p50Milliseconds == 50)
        #expect(summary.p95Milliseconds == 95)
        #expect(summary.p99Milliseconds == 99)
        #expect(summary.maxMilliseconds == 100)
        let twenty = try #require(TransportLatencySummary(milliseconds: (1...20).map(Double.init)))
        #expect(twenty.p50Milliseconds == 10)
        #expect(twenty.p95Milliseconds == 19)
        #expect(twenty.p99Milliseconds == 20)
        let single = try #require(TransportLatencySummary(milliseconds: [7]))
        #expect(single.p50Milliseconds == 7 && single.p99Milliseconds == 7)
    }

    @Test func invalidSamplesDoNotProduceMisleadingSummaries() {
        #expect(TransportLatencySummary(milliseconds: []) == nil)
        #expect(TransportLatencySummary(milliseconds: [-1]) == nil)
        #expect(TransportLatencySummary(milliseconds: [.nan]) == nil)
        #expect(TransportLatencySummary(milliseconds: [.infinity]) == nil)
    }
}
