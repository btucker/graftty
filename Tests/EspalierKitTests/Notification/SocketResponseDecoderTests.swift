import Testing
import Foundation
@testable import EspalierKit

@Suite("SocketResponseDecoder")
struct SocketResponseDecoderTests {

    @Test func emptyBufferIsTimeout() {
        // Pre-cycle-138, the CLI threw `socketError("Empty response
        // from app")` here — misleading because the actual cause is
        // almost always a timeout (client SO_RCVTIMEO or server-side
        // onRequestTimeout closing fd without a response).
        let result = SocketResponseDecoder.decode(Data())
        #expect(result == .failure(.timeout))
    }

    @Test func okResponseDecodes() {
        let data = #"{"type":"ok"}"#.data(using: .utf8)! + Data([0x0A])
        let result = SocketResponseDecoder.decode(data)
        guard case .success(let msg) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(msg == .ok)
    }

    @Test func errorResponseDecodes() {
        let data = #"{"type":"error","message":"boom"}"#.data(using: .utf8)! + Data([0x0A])
        let result = SocketResponseDecoder.decode(data)
        #expect(result == .success(.error("boom")))
    }

    @Test func paneListResponseDecodes() {
        let data = #"{"type":"pane_list","panes":[]}"#.data(using: .utf8)! + Data([0x0A])
        let result = SocketResponseDecoder.decode(data)
        #expect(result == .success(.paneList([])))
    }

    @Test func garbageBytesAreUnparseable() {
        // Non-empty buffer that isn't a valid JSON ResponseMessage.
        let result = SocketResponseDecoder.decode(Data("not json".utf8))
        #expect(result == .failure(.unparseable))
    }

    @Test func onlyNewlinesAreUnparseable() {
        // The `first(where: !isEmpty)` component filter finds nothing.
        let result = SocketResponseDecoder.decode(Data("\n\n\n".utf8))
        #expect(result == .failure(.unparseable))
    }

    @Test func responseWithTrailingJunkStillDecodesFirstLine() {
        // Server appends `\n` after the JSON; anything after is
        // ignored. Harmless robustness against an overly-chatty
        // future server.
        let data = #"{"type":"ok"}"# + "\ntrailing garbage"
        let result = SocketResponseDecoder.decode(Data(data.utf8))
        #expect(result == .success(.ok))
    }

    @Test func nonUTF8BufferIsUnparseable() {
        // Invalid UTF-8 sequence: lone 0xFF continuation byte.
        let result = SocketResponseDecoder.decode(Data([0xFF, 0xFE, 0xFD]))
        #expect(result == .failure(.unparseable))
    }
}
