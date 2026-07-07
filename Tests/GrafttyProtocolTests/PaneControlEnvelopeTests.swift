import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PaneControlRequest wire format")
struct PaneControlEnvelopeTests {

    @Test
    func splitRoundTrips() throws {
        let req: PaneControlRequest = .split(target: "session-a", direction: .right)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test("""
@spec REMOTE-7.7: Pane-control split requests shall encode semantic directions right/down/left/up, and legacy horizontal/vertical split directions shall decode as right/down for compatibility.
""")
    func semanticDirectionsAndLegacyAxes() throws {
        let request = PaneControlRequest.split(target: "s", direction: .left)
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["direction"] as? String == "left")

        let legacyHorizontal = Data(#"{"type":"split","target":"s","direction":"horizontal"}"#.utf8)
        let legacyVertical = Data(#"{"type":"split","target":"s","direction":"vertical"}"#.utf8)
        #expect(try JSONDecoder().decode(PaneControlRequest.self, from: legacyHorizontal) == .split(target: "s", direction: .right))
        #expect(try JSONDecoder().decode(PaneControlRequest.self, from: legacyVertical) == .split(target: "s", direction: .down))
    }

    @Test
    func allSemanticDirectionsRoundTrip() throws {
        for direction in PaneControlRequest.SplitDirection.allCases {
            let original = PaneControlRequest.split(target: "session", direction: direction)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(PaneControlRequest.self, from: data) == original)
        }
    }

    @Test
    func closeRoundTrips() throws {
        let req: PaneControlRequest = .close(target: "session-b")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func swapRoundTrips() throws {
        let req: PaneControlRequest = .swap(source: "session-a", target: "session-c")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func unknownRequestTypeThrows() throws {
        let json = Data(#"{"type":"unknown-op","target":"x"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PaneControlRequest.self, from: json)
        }
    }

    @Test
    func okResponseRoundTrips() throws {
        let resp: PaneControlResponse = .ok
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        #expect(decoded == resp)
    }

    @Test
    func errorResponseRoundTrips() throws {
        let resp: PaneControlResponse = .error(code: "conflict", message: "target already split")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        #expect(decoded == resp)
    }
}
