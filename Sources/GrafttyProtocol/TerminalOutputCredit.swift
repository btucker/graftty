import Foundation

/// REMOTE-9.19: receiver-driven pacing for terminal output on the SSH session
/// channel. NIOSSH fixes each channel's window at 16 MiB and `.stdErr` control
/// frames share it, so SSH flow control alone leaves control behind that whole
/// backlog. A smaller output window keeps the SSH window open for control.
///
/// A client opts in with an `env` request before `shell`. Hosts accept unknown
/// env names silently and drop unknown control frames, so both directions stay
/// compatible with older peers, which fall back to SSH flow control.
public enum TerminalOutputCredit {
    public static let environmentName = "GRAFTTY_TERMINAL_OUTPUT_WINDOW"
    /// Covers about 10 MB/s at 100 ms RTT, and keeps the backlog ahead of a
    /// control frame well under a second at the slowest measured parser rate.
    public static let clientWindowBytes = 1024 * 1024
    /// Must exceed the host's largest output slice so a write can always fit.
    private static let windowBytesRange = (64 * 1024)...(1 << 24)
    private static let consumedType = "outputConsumed"
    /// Longer than any total, so larger control frames skip a JSON parse.
    private static let maxConsumedFrameBytes = 64

    /// Returns the window a client requested, or nil for an invalid value.
    public static func parseWindow(_ value: String) -> Int? {
        guard let bytes = Int(value), windowBytesRange.contains(bytes) else { return nil }
        return bytes
    }

    /// Acknowledgements carry a cumulative total, so they are idempotent and a
    /// late one cannot move the window backward.
    public static func encodeConsumed(_ bytes: UInt64) -> String {
        "{\"bytes\":\(bytes),\"type\":\"\(consumedType)\"}"
    }

    public static func parseConsumed(_ payload: Data) -> UInt64? {
        guard payload.count <= maxConsumedFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["type"] as? String == consumedType,
              let number = object["bytes"] as? NSNumber,
              number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }
}
