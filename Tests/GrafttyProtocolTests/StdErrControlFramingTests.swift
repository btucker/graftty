import Foundation
import Testing
@testable import GrafttyProtocol

/// Covers the `<u32 BE length><UTF-8 bytes>` wire codec shared by
/// `TerminalSessionHandler` (host) and `TerminalSessionClient`/
/// `InboundRelay` (mobile) on the SSH session channel's `.stdErr`
/// control carrier. See `StdErrControlFraming`'s type doc comment for
/// the authoritative wire-format description.
@Suite
struct StdErrControlFramingTests {

    @Test
    func encodesLengthPrefixAndUTF8Payload() {
        let framed = StdErrControlFraming.encode("ABC")
        #expect(framed == [0x00, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43])
    }

    @Test
    func encodesEmptyPayloadAsZeroLengthFrame() {
        let framed = StdErrControlFraming.encode("")
        #expect(framed == [0x00, 0x00, 0x00, 0x00])
    }

    @Test
    func roundTripsThroughDecoder() {
        let framed = StdErrControlFraming.encode(#"{"type":"hello"}"#)!
        var decoder = StdErrControlFraming.Decoder()
        decoder.append(framed)
        let (frames, oversized) = decoder.drain()
        #expect(!oversized)
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == #"{"type":"hello"}"#)
    }

    @Test
    func accumulatesAPartialFrameAcrossMultipleAppends() {
        let framed = StdErrControlFraming.encode("hello world")!
        var decoder = StdErrControlFraming.Decoder()

        // Feed only the length header first — no complete frame yet.
        decoder.append(framed[0..<4])
        var (frames, oversized) = decoder.drain()
        #expect(frames.isEmpty)
        #expect(!oversized)

        // Feed the payload in two more chunks.
        decoder.append(framed[4..<8])
        (frames, oversized) = decoder.drain()
        #expect(frames.isEmpty)
        #expect(!oversized)

        decoder.append(framed[8...])
        (frames, oversized) = decoder.drain()
        #expect(!oversized)
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == "hello world")
    }

    @Test
    func drainsMultipleFramesDeliveredInOneChunk() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: StdErrControlFraming.encode("first")!)
        bytes.append(contentsOf: StdErrControlFraming.encode("second")!)
        bytes.append(contentsOf: StdErrControlFraming.encode("third")!)

        var decoder = StdErrControlFraming.Decoder()
        decoder.append(bytes)
        let (frames, oversized) = decoder.drain()

        #expect(!oversized)
        #expect(frames.map { String(data: $0, encoding: .utf8) } == ["first", "second", "third"])
    }

    @Test
    func leavesATrailingPartialFrameBufferedAfterDrainingCompleteOnes() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: StdErrControlFraming.encode("complete")!)
        bytes.append(contentsOf: StdErrControlFraming.encode("partial")!.prefix(5))

        var decoder = StdErrControlFraming.Decoder()
        decoder.append(bytes)
        var (frames, oversized) = decoder.drain()
        #expect(!oversized)
        #expect(frames.map { String(data: $0, encoding: .utf8) } == ["complete"])

        // Finish the trailing frame.
        decoder.append(StdErrControlFraming.encode("partial")!.suffix(from: 5))
        (frames, oversized) = decoder.drain()
        #expect(!oversized)
        #expect(frames.map { String(data: $0, encoding: .utf8) } == ["partial"])
    }

    @Test
    func oversizedLengthHeaderReportsOversizedAndStopsDraining() {
        // A length prefix above maxFrameLength — framing is unrecoverable
        // from this point (mirrors TerminalSessionHandler.drainControlFrames
        // / InboundRelay.ingestControlBytes).
        var decoder = StdErrControlFraming.Decoder()
        decoder.append([0xff, 0xff, 0xff, 0xf0, 0x41, 0x42, 0x43])
        let (frames, oversized) = decoder.drain()
        #expect(oversized)
        #expect(frames.isEmpty)
    }

    @Test
    func oversizedFrameStillReturnsCompleteFramesDrainedBeforeIt() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: StdErrControlFraming.encode("ok")!)
        bytes.append(contentsOf: [0xff, 0xff, 0xff, 0xf0, 0x41, 0x42, 0x43])

        var decoder = StdErrControlFraming.Decoder()
        decoder.append(bytes)
        let (frames, oversized) = decoder.drain()
        #expect(oversized)
        #expect(frames.map { String(data: $0, encoding: .utf8) } == ["ok"])
    }

    @Test
    func resetClearsBufferedBytesAfterOversizedFrame() {
        var decoder = StdErrControlFraming.Decoder()
        decoder.append([0xff, 0xff, 0xff, 0xf0])
        _ = decoder.drain()
        decoder.reset()

        // A fresh, well-formed frame decodes cleanly after reset — no
        // leftover bytes from the poisoned header remain.
        decoder.append(StdErrControlFraming.encode("fresh")!)
        let (frames, oversized) = decoder.drain()
        #expect(!oversized)
        #expect(frames.map { String(data: $0, encoding: .utf8) } == ["fresh"])
    }

    @Test
    func isOverAccumulatedIsFalseUnderTheCapWithNoCompleteFrame() {
        var decoder = StdErrControlFraming.Decoder()
        // Just the length header claiming a frame right at the cap —
        // no violation yet, and not enough bytes for a complete frame.
        let capLength = StdErrControlFraming.maxFrameLength
        decoder.append([
            UInt8((capLength >> 24) & 0xff),
            UInt8((capLength >> 16) & 0xff),
            UInt8((capLength >> 8) & 0xff),
            UInt8(capLength & 0xff),
        ])
        #expect(!decoder.isOverAccumulated)
    }

    @Test
    func isOverAccumulatedIsTrueOnceUndrainedBytesExceedCapPlusHeader() {
        var decoder = StdErrControlFraming.Decoder()
        // More than maxFrameLength + 4 undrained bytes with no complete
        // frame in sight (no valid length header at all here) — mirrors
        // TerminalSessionHandler.ingestStdErr's pre-attach accumulation
        // bound.
        let tooMany = Int(StdErrControlFraming.maxFrameLength) + 5
        decoder.append([UInt8](repeating: 0, count: tooMany))
        #expect(decoder.isOverAccumulated)
    }
}
