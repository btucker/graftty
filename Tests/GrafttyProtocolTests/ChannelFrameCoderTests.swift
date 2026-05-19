import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("ChannelFrameCoder — encode/decode round-trip across all four FrameType variants.")
struct ChannelFrameCoderTests {

    @Test
    func openFrameRoundTrips() throws {
        let frame: ChannelFrame = .open(ChannelOpen(id: ChannelID(7), type: "terminal"))
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func closeFrameRoundTrips() throws {
        let frame: ChannelFrame = .close(ChannelClose(id: ChannelID(42)))
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func payloadFrameRoundTrips() throws {
        let payload = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0xFF])
        let frame: ChannelFrame = .payload(ChannelPayload(id: ChannelID(13)), payload)
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func emptyPayloadFrameRoundTrips() throws {
        let frame: ChannelFrame = .payload(ChannelPayload(id: ChannelID(1)), Data())
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func errorFrameRoundTrips() throws {
        let frame: ChannelFrame = .error(ChannelError(
            id: ChannelID(99),
            code: "channel-type-unknown",
            message: "no handler factory for type 'panes_state'"
        ))
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func decodeTruncatedHeaderThrows() throws {
        let bytes = Data([0x01, 0x00, 0x00])
        #expect(throws: ChannelFrameCoder.DecodeError.truncated) {
            try ChannelFrameCoder.decode(bytes)
        }
    }

    @Test
    func decodeUnknownTypeThrows() throws {
        // type byte 0x99 is not a valid FrameType; the 8 zero bytes after
        // satisfy the minimum header-length check.
        let bytes = Data([0x99, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: ChannelFrameCoder.DecodeError.unknownType(0x99)) {
            try ChannelFrameCoder.decode(bytes)
        }
    }

    @Test
    func decodeShortMetadataThrows() throws {
        // type=open, metadata length=100, but only 3 bytes of metadata follow
        // before the payload-length field. Should be flagged as truncated
        // when reading metadata.
        var bytes = Data([0x01])
        bytes.append(contentsOf: [0x64, 0x00, 0x00, 0x00]) // metadataLength = 100
        bytes.append(contentsOf: [0x00, 0x00, 0x00])       // 3 bytes only
        #expect(throws: ChannelFrameCoder.DecodeError.truncated) {
            try ChannelFrameCoder.decode(bytes)
        }
    }

    @Test
    func decodeMalformedJSONMetadataThrowsMalformedJSON() throws {
        // type=open (0x01), metadataLength=4, metadata="bogu" (not valid JSON),
        // payloadLength=0
        var bytes = Data([0x01])
        bytes.append(contentsOf: [0x04, 0x00, 0x00, 0x00]) // metadata length = 4
        bytes.append(Data("bogu".utf8))                     // 4 bytes of bad JSON
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // payload length = 0
        do {
            _ = try ChannelFrameCoder.decode(bytes)
            Issue.record("expected throw")
        } catch let error as ChannelFrameCoder.DecodeError {
            guard case .malformedJSON = error else {
                Issue.record("expected .malformedJSON, got \(error)")
                return
            }
        }
    }
}
