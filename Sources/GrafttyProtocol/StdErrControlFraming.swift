import Foundation

/// Wire codec for the REMOTE-9 `.stdErr` control carrier shared by
/// `GrafttyHostAgent`'s `TerminalSessionHandler` (server side) and
/// `GrafttyMobileKit`'s `TerminalSessionClient`/`InboundRelay` (client
/// side). Both ends multiplex a length-prefixed control-envelope stream
/// onto the SSH session channel's `.stdErr` sub-stream, alongside (but
/// framed separately from) raw PTY bytes on `.channel` — see
/// `TerminalSessionHandler`'s type doc comment for why this can't ride
/// the `LengthPrefixedFraming` pipeline handlers the subsystem channels
/// use.
///
/// **Wire format**, authoritative here (both ends previously hand-mirrored
/// this — see the type doc comments this replaces):
///
///     <u32 BE length><UTF-8 bytes>
///
/// `length` is the byte count of the UTF-8 payload that follows — NOT
/// including the 4-byte header itself. Multiple frames are simply
/// concatenated; there is no delimiter or padding between them.
///
/// This type is pure (no NIO/Foundation-networking, no UIKit/AppKit) so
/// all three targets that need it — `GrafttyHostAgent`, `GrafttyMobileKit`,
/// and their test targets — can depend on it via `GrafttyProtocol` without
/// pulling in platform- or transport-specific dependencies.
public enum StdErrControlFraming {
    /// Upper bound on a single frame's declared payload length. Control
    /// envelopes are small JSON (hello/takeControl/ownership — hundreds of
    /// bytes); 1 MiB is orders of magnitude above any real frame while
    /// bounding what a buggy/hostile peer can make either end buffer.
    public static let maxFrameLength: UInt32 = 1 << 20

    /// Frames `payload` as `<u32 BE length><UTF-8 bytes>`. Returns `nil`
    /// only if `payload`'s UTF-8 byte count somehow exceeds `UInt32.max` —
    /// a control envelope can never approach that in practice, but a
    /// guard (rather than a trap or a clamp, which would desync the
    /// framing) keeps this total.
    public static func encode(_ payload: String) -> [UInt8]? {
        let bytes = Array(payload.utf8)
        guard let length = UInt32(exactly: bytes.count) else { return nil }
        var framed: [UInt8] = [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]
        framed.append(contentsOf: bytes)
        return framed
    }

    /// Stateful accumulator/decoder for the wire format above. Callers
    /// append raw inbound bytes as they arrive (which may split a frame
    /// arbitrarily) and call `drain()` to pull out every complete frame
    /// currently available, leaving any partial trailing frame buffered
    /// for the next `append`.
    ///
    /// Mirrors the cursor-based draining `TerminalSessionHandler` and
    /// `TerminalSessionClient` each used to hand-roll: consumed bytes are
    /// tracked via an internal cursor rather than removed immediately
    /// (advancing an `Int` per frame is O(1), so a burst of k buffered
    /// frames drains in O(k) instead of the O(n·k) a per-frame
    /// `removeFirst` would cost), and the accumulator is compacted with a
    /// single `removeSubrange` once per `drain()` call, regardless of how
    /// many frames were drained in that pass.
    public struct Decoder {
        private var accumulator: [UInt8] = []
        private var cursor = 0

        public init() {}

        /// Appends raw inbound bytes to the accumulator. Does not itself
        /// extract frames — call `drain()` for that.
        public mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            accumulator.append(contentsOf: bytes)
        }

        /// Extracts every complete frame currently available, in order,
        /// compacting the accumulator once at the end of the pass.
        ///
        /// If a frame's declared length header exceeds `maxFrameLength`,
        /// draining stops immediately at that frame (frames found before
        /// it are still returned) and `oversized` is `true` — framing is
        /// unrecoverable at that point (there's no way to tell where the
        /// next frame starts), so callers MUST treat `oversized` as fatal
        /// to the carrier: stop draining, discard all buffered bytes
        /// (`reset()`), and apply whatever poison-the-carrier policy suits
        /// the call site (both current call sites drop all future
        /// `.stdErr` bytes; some additionally close the channel — that
        /// policy lives at the call site, not here).
        public mutating func drain() -> (frames: [Data], oversized: Bool) {
            var frames: [Data] = []
            var oversized = false
            while accumulator.count - cursor >= 4 {
                let base = cursor
                let length = (UInt32(accumulator[base]) << 24)
                    | (UInt32(accumulator[base + 1]) << 16)
                    | (UInt32(accumulator[base + 2]) << 8)
                    | UInt32(accumulator[base + 3])
                guard length <= StdErrControlFraming.maxFrameLength else {
                    oversized = true
                    break
                }
                let total = 4 + Int(length)
                guard accumulator.count - base >= total else { break }
                frames.append(Data(accumulator[(base + 4)..<(base + total)]))
                cursor = base + total
            }
            if cursor > 0 {
                accumulator.removeSubrange(0..<cursor)
                cursor = 0
            }
            return (frames, oversized)
        }

        /// `true` when undrained accumulation past the cursor exceeds one
        /// max-size frame's worth of bytes with no complete frame in
        /// sight — a protocol violation distinct from (and cheaper to
        /// check than) the per-frame `oversized` signal from `drain()`,
        /// since it also bounds pre-attach buffering where a caller may
        /// intentionally defer draining (e.g. `TerminalSessionHandler`
        /// buffers `.hello` bytes before its coordinator exists).
        public var isOverAccumulated: Bool {
            accumulator.count - cursor > Int(StdErrControlFraming.maxFrameLength) + 4
        }

        /// Discards all buffered bytes and resets the cursor. Callers use
        /// this to poison the carrier after an `oversized` drain or an
        /// `isOverAccumulated` violation.
        public mutating func reset() {
            accumulator = []
            cursor = 0
        }
    }
}
