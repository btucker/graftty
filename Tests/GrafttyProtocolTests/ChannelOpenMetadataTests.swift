import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("ChannelOpen metadata — Codable round-trip with and without metadata.")
struct ChannelOpenMetadataTests {

    @Test
    func metadataNilRoundTrips() throws {
        let open = ChannelOpen(id: ChannelID(5), type: "panes_state")
        let data = try JSONEncoder().encode(open)
        let decoded = try JSONDecoder().decode(ChannelOpen.self, from: data)
        #expect(decoded == open)
        #expect(decoded.metadata == nil)
    }

    @Test
    func metadataPresentRoundTrips() throws {
        let blob = Data([0x01, 0x02, 0x03, 0x04])
        let open = ChannelOpen(id: ChannelID(9), type: "terminal", metadata: blob)
        let data = try JSONEncoder().encode(open)
        let decoded = try JSONDecoder().decode(ChannelOpen.self, from: data)
        #expect(decoded == open)
        #expect(decoded.metadata == blob)
    }

    @Test
    func backwardCompatibleDecodeAcceptsLegacyShape() throws {
        // A peer running pre-M2a code wouldn't emit the metadata field;
        // we must still decode their `{"id":1,"type":"x"}` payload.
        let legacy = Data(#"{"id":1,"type":"panes_state"}"#.utf8)
        let decoded = try JSONDecoder().decode(ChannelOpen.self, from: legacy)
        #expect(decoded.id == ChannelID(1))
        #expect(decoded.type == "panes_state")
        #expect(decoded.metadata == nil)
    }
}
