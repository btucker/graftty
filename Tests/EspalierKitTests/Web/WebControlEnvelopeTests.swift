import Testing
import Foundation
@testable import EspalierKit

@Suite("WebControlEnvelope — parse")
struct WebControlEnvelopeTests {

    @Test func validResize() throws {
        let json = #"{"type":"resize","cols":120,"rows":40}"#
        let env = try WebControlEnvelope.parse(Data(json.utf8))
        guard case let .resize(cols, rows) = env else {
            Issue.record("expected .resize, got \(env)"); return
        }
        #expect(cols == 120 && rows == 40)
    }

    @Test func resizeIgnoresExtraFields() throws {
        let json = #"{"type":"resize","cols":80,"rows":24,"extraneous":"ok"}"#
        let env = try WebControlEnvelope.parse(Data(json.utf8))
        guard case let .resize(cols, rows) = env else {
            Issue.record("expected .resize"); return
        }
        #expect(cols == 80 && rows == 24)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data("not json".utf8))
        }
    }

    @Test func missingFieldsThrow() {
        let json = #"{"type":"resize","cols":80}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }

    @Test func negativeDimensionsThrow() {
        let json = #"{"type":"resize","cols":-1,"rows":24}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }

    @Test func zeroDimensionsThrow() {
        let json = #"{"type":"resize","cols":0,"rows":24}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }

    @Test func unknownTypeThrows() {
        let json = #"{"type":"unknown"}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }
}
