import Foundation

/// Receiver-side credit policy. Acknowledgements remain cumulative bytes that
/// were actually delivered, so existing hosts need no new wire messages.
struct TerminalOutputPacing {
    let maximumWindowBytes: Int
    private(set) var windowBytes: Int
    let adaptive: Bool
    private var delivery: (bytes: Int, time: UInt64)?

    init(windowBytes: Int, adaptive: Bool) {
        maximumWindowBytes = windowBytes
        self.windowBytes = windowBytes
        self.adaptive = adaptive
    }

    mutating func didDeliver(bytes: Int, atNanoseconds now: UInt64) {
        guard adaptive, bytes > 0 else { return }
        delivery = (bytes, now)
    }

    mutating func consumerReady(atNanoseconds now: UInt64) {
        guard let delivery else { return }
        self.delivery = nil
        guard now > delivery.time else { return }
        // Measure only delivery -> next receive, excluding the network wait.
        // Target roughly 1/16 second of consumer work, within the negotiated
        // ceiling. Already granted credit cannot be retracted.
        let desired = Double(delivery.bytes) * 62_500_000 / Double(now - delivery.time)
        windowBytes = desired >= Double(maximumWindowBytes) ? maximumWindowBytes
            : max(min(maximumWindowBytes, 128 * 1024), Int(desired))
    }

    func acknowledgement(consumed: UInt64, acknowledged: UInt64) -> UInt64? {
        let held = UInt64(maximumWindowBytes - windowBytes)
        let available = consumed > held ? consumed - held : 0
        let quantum = adaptive ? max(16 * 1024, windowBytes / 8) : maximumWindowBytes / 8
        guard available > acknowledged,
              available - acknowledged >= UInt64(quantum) else { return nil }
        return available
    }
}
