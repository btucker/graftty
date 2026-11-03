/// @spec SSH-1.9
/// While an SSH-over-WebRTC transport is active or closed, the application shall expose bounded numeric send diagnostics for queued bytes, WebRTC buffering, completed and failed writes, and local write-admission delay without retaining payloads.
public struct WebRTCSendDiagnostics: Codable, Equatable, Sendable {
    public internal(set) var acceptedBytes: UInt64 = 0
    public internal(set) var submittedBytes: UInt64 = 0
    public internal(set) var pendingBytes: Int = 0
    public internal(set) var peakPendingBytes: Int = 0
    public internal(set) var bufferedBytes: UInt64 = 0
    public internal(set) var peakBufferedBytes: UInt64 = 0
    public internal(set) var completedWrites: UInt64 = 0
    public internal(set) var failedWrites: UInt64 = 0
    public internal(set) var totalAdmissionNanoseconds: UInt64 = 0
    public internal(set) var maxAdmissionNanoseconds: UInt64 = 0

    /// Time from enqueue until the complete write enters WebRTC's local send
    /// buffer. This does not measure network delivery or remote consumption.
    public var meanAdmissionMilliseconds: Double? {
        guard completedWrites > 0 else { return nil }
        return Double(totalAdmissionNanoseconds) / Double(completedWrites) / 1_000_000
    }

    public var maxAdmissionMilliseconds: Double {
        Double(maxAdmissionNanoseconds) / 1_000_000
    }
}
