import Foundation

/// A numeric report that discards individual samples after computing the
/// nearest-rank percentiles. SSH-1.10 covers the reporting contract.
public struct TransportLatencySummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
    public let maxMilliseconds: Double

    public init?(milliseconds: [Double]) {
        guard !milliseconds.isEmpty, milliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let sorted = milliseconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[Int(ceil(Double(sorted.count) * fraction)) - 1]
        }
        sampleCount = sorted.count
        p50Milliseconds = percentile(0.50)
        p95Milliseconds = percentile(0.95)
        p99Milliseconds = percentile(0.99)
        maxMilliseconds = sorted[sorted.count - 1]
    }
}
