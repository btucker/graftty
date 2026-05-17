import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PaneControlRequest/Response — encode/decode round-trip for every variant.")
struct PaneControlEnvelopeTests {

    @Test
    func splitRoundTrips() throws {
        let req: PaneControlRequest = .split(target: "session-a", direction: .horizontal)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
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
