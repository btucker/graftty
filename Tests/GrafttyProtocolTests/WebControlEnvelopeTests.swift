import Foundation
import Testing
@testable import GrafttyProtocol

@Suite
struct WebControlEnvelopeTests {

    @Test
    func parsesResizeEnvelope() throws {
        let json = #"{"type":"resize","cols":80,"rows":24}"#.data(using: .utf8)!
        let envelope = try WebControlEnvelope.parse(json)
        #expect(envelope == .resize(cols: 80, rows: 24))
    }

    @Test
    func rejectsNonJSONPayload() {
        #expect(throws: WebControlEnvelope.ParseError.notJSON) {
            try WebControlEnvelope.parse(Data("not json".utf8))
        }
    }

    @Test
    func rejectsUnknownType() {
        let json = #"{"type":"mystery"}"#.data(using: .utf8)!
        #expect(throws: WebControlEnvelope.ParseError.unknownType("mystery")) {
            try WebControlEnvelope.parse(json)
        }
    }

    @Test
    func rejectsMissingDimension() {
        let json = #"{"type":"resize","cols":80}"#.data(using: .utf8)!
        #expect(throws: WebControlEnvelope.ParseError.missingField("rows")) {
            try WebControlEnvelope.parse(json)
        }
    }

    @Test
    func rejectsZeroOrOverLargeDimensions() {
        let zero = #"{"type":"resize","cols":0,"rows":24}"#.data(using: .utf8)!
        #expect(throws: WebControlEnvelope.ParseError.invalidDimension) {
            try WebControlEnvelope.parse(zero)
        }
        let huge = #"{"type":"resize","cols":20000,"rows":20000}"#.data(using: .utf8)!
        #expect(throws: WebControlEnvelope.ParseError.invalidDimension) {
            try WebControlEnvelope.parse(huge)
        }
    }
}
