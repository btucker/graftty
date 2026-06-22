import Foundation
import Testing
@testable import GrafttyProtocol

@Suite
struct WebControlEnvelopeTests {

    @Test
    func parsesLegacyResizeEnvelope() throws {
        let json = #"{"type":"resize","cols":80,"rows":24}"#.data(using: .utf8)!
        let envelope = try WebControlEnvelope.parse(json)
        #expect(envelope == .resize(cols: 80, rows: 24))
    }

    @Test
    func parsesHelloEnvelope() throws {
        let json = #"{"type":"hello","clientID":"web-1","kind":"web","role":"interactive","visible":true,"cols":100,"rows":32}"#
        let envelope = try WebControlEnvelope.parse(Data(json.utf8))
        #expect(envelope == .hello(
            clientID: DisplayClientID("web-1"),
            kind: .web,
            role: .interactive,
            visible: true,
            cols: 100,
            rows: 32
        ))
    }

    @Test
    func parsesTakeControlEnvelope() throws {
        let json = #"{"type":"takeControl","clientID":"ios-1","kind":"ios","cols":90,"rows":28}"#
        let envelope = try WebControlEnvelope.parse(Data(json.utf8))
        #expect(envelope == .takeControl(
            clientID: DisplayClientID("ios-1"),
            kind: .ios,
            cols: 90,
            rows: 28
        ))
    }

    @Test
    func parsesOwnerResizeEnvelope() throws {
        let json = #"{"type":"ownerResize","clientID":"mac-1","epoch":3,"cols":120,"rows":40}"#
        let envelope = try WebControlEnvelope.parse(Data(json.utf8))
        #expect(envelope == .ownerResize(
            clientID: DisplayClientID("mac-1"),
            epoch: 3,
            cols: 120,
            rows: 40
        ))
    }

    @Test
    func parsesOwnershipEnvelope() throws {
        let json = #"{"type":"ownership","snapshot":{"sessionName":"main","ownerClientID":"web-1","ownerKind":"web","grid":{"cols":100,"rows":30},"epoch":2,"ownerless":false}}"#
        let envelope = try WebControlEnvelope.parse(Data(json.utf8))
        #expect(envelope == .ownership(try DisplayOwnershipSnapshot(
            sessionName: "main",
            ownerClientID: DisplayClientID("web-1"),
            ownerKind: .web,
            grid: try DisplayGrid(cols: 100, rows: 30),
            epoch: 2
        )))
    }

    @Test
    func encodesOwnerAwareEnvelopes() throws {
        let hello = WebControlEnvelope.hello(
            clientID: DisplayClientID("web-1"),
            kind: .web,
            role: .interactive,
            visible: true,
            cols: 100,
            rows: 32
        )
        #expect(try WebControlEnvelope.parse(Data(hello.encoded().utf8)) == hello)

        let takeControl = WebControlEnvelope.takeControl(
            clientID: DisplayClientID("ios-1"),
            kind: .ios,
            cols: 90,
            rows: 28
        )
        #expect(try WebControlEnvelope.parse(Data(takeControl.encoded().utf8)) == takeControl)

        let ownerResize = WebControlEnvelope.ownerResize(
            clientID: DisplayClientID("mac-1"),
            epoch: UInt64.max,
            cols: 120,
            rows: 40
        )
        #expect(try WebControlEnvelope.parse(Data(ownerResize.encoded().utf8)) == ownerResize)

        let snapshot = try DisplayOwnershipSnapshot(
            sessionName: "main",
            ownerClientID: nil,
            ownerKind: nil,
            grid: try DisplayGrid(cols: 80, rows: 24),
            epoch: 4
        )
        let ownership = WebControlEnvelope.ownership(snapshot)
        #expect(try WebControlEnvelope.parse(Data(ownership.encoded().utf8)) == ownership)
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
    func rejectsMissingOwnerAwareFields() {
        let json = #"{"type":"hello","clientID":"web-1","kind":"web","role":"interactive","cols":80,"rows":24}"#
        #expect(throws: WebControlEnvelope.ParseError.missingField("visible")) {
            try WebControlEnvelope.parse(Data(json.utf8))
        }
    }

    @Test
    func rejectsOwnershipSnapshotWithOnlyOneOwnerField() {
        let missingKind = #"{"type":"ownership","snapshot":{"sessionName":"main","ownerClientID":"web-1","grid":{"cols":100,"rows":30},"epoch":2,"ownerless":false}}"#
        #expect(throws: WebControlEnvelope.ParseError.invalidField("snapshot")) {
            try WebControlEnvelope.parse(Data(missingKind.utf8))
        }

        let missingID = #"{"type":"ownership","snapshot":{"sessionName":"main","ownerKind":"web","grid":{"cols":100,"rows":30},"epoch":2,"ownerless":false}}"#
        #expect(throws: WebControlEnvelope.ParseError.invalidField("snapshot")) {
            try WebControlEnvelope.parse(Data(missingID.utf8))
        }
    }

    @Test
    func rejectsZeroOrOutOfUInt16Dimensions() {
        let zero = #"{"type":"resize","cols":0,"rows":24}"#.data(using: .utf8)!
        #expect(throws: WebControlEnvelope.ParseError.invalidDimension) {
            try WebControlEnvelope.parse(zero)
        }
        let huge = #"{"type":"resize","cols":70000,"rows":24}"#.data(using: .utf8)!
        #expect(throws: WebControlEnvelope.ParseError.invalidDimension) {
            try WebControlEnvelope.parse(huge)
        }
    }

    @Test
    func rejectsDimensionsAboveOperationalWireLimit() {
        let payloads = [
            #"{"type":"resize","cols":10001,"rows":24}"#,
            #"{"type":"grid","cols":80,"rows":10001}"#,
            #"{"type":"hello","clientID":"web-1","kind":"web","role":"interactive","visible":true,"cols":10001,"rows":24}"#,
            #"{"type":"takeControl","clientID":"web-1","kind":"web","cols":10001,"rows":24}"#,
            #"{"type":"ownerResize","clientID":"web-1","epoch":1,"cols":10001,"rows":24}"#,
            #"{"type":"ownership","snapshot":{"sessionName":"main","ownerClientID":"web-1","ownerKind":"web","grid":{"cols":10001,"rows":24},"epoch":2,"ownerless":false}}"#,
        ]

        for payload in payloads {
            #expect(throws: WebControlEnvelope.ParseError.invalidDimension) {
                try WebControlEnvelope.parse(Data(payload.utf8))
            }
        }
    }

    @Test
    func ownershipSnapshotRoundTripsThroughCodable() throws {
        let snapshot = try DisplayOwnershipSnapshot(
            sessionName: "main",
            ownerClientID: DisplayClientID("ios-1"),
            ownerKind: .ios,
            grid: try DisplayGrid(cols: 132, rows: 43),
            epoch: 9
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DisplayOwnershipSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.isOwnerless == false)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ownerless"] as? Bool == false)
    }

    @Test
    func constructingSnapshotWithOnlyOneOwnerFieldThrows() throws {
        #expect(throws: DisplayOwnershipSnapshot.ValidationError.inconsistentOwnerFields) {
            try DisplayOwnershipSnapshot(
                sessionName: "main",
                ownerClientID: DisplayClientID("web-1"),
                ownerKind: nil,
                grid: try DisplayGrid(cols: 80, rows: 24),
                epoch: 1
            )
        }

        #expect(throws: DisplayOwnershipSnapshot.ValidationError.inconsistentOwnerFields) {
            try DisplayOwnershipSnapshot(
                sessionName: "main",
                ownerClientID: nil,
                ownerKind: .web,
                grid: try DisplayGrid(cols: 80, rows: 24),
                epoch: 1
            )
        }
    }
}
