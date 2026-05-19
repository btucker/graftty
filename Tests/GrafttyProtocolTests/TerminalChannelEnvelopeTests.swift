import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("TerminalChannelOpenMeta — Codable round-trip.")
struct TerminalChannelEnvelopeTests {

    @Test
    func roundTrips() throws {
        let meta = TerminalChannelOpenMeta(sessionName: "graftty-feature-branch-shell")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(TerminalChannelOpenMeta.self, from: data)
        #expect(decoded == meta)
    }
}
