import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("Attention.source — carries provenance so the resume rule can target agent-stop pings; legacy payloads decode as .userNotify.")
struct AttentionSourceTests {
    @Test func sourceRoundTrips() throws {
        let a = Attention(
            text: "Claude needs input",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            clearAfter: nil,
            source: .agentStop)
        let decoded = try JSONDecoder().decode(
            Attention.self, from: try JSONEncoder().encode(a))
        #expect(decoded.source == .agentStop)
        #expect(decoded == a)
    }

    @Test func defaultsToUserNotify() {
        #expect(Attention(text: "ping", timestamp: Date(timeIntervalSince1970: 1)).source == .userNotify)
    }

    @Test func legacyPayloadWithoutSourceDecodesAsUserNotify() throws {
        // A persisted state.json from before `source` existed must still
        // decode rather than fail — and not be treated as agent-stop (which
        // would let the resume rule wipe a user ping).
        let legacy = #"{"text":"ping","timestamp":631152000}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Attention.self, from: legacy)
        #expect(decoded.source == .userNotify)
    }
}
