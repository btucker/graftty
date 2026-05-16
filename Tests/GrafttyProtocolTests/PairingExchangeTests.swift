import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PairingExchange wire shape roundtrips")
struct PairingExchangeRoundtripTests {

    // MARK: Fixtures

    private static func fixturePublicKey(byte: UInt8) -> RemoteIdentityPublicKey {
        try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private static func fixtureNonce() -> RemotePairingNonce {
        RemotePairingNonce(bytes: Data(repeating: 0x42, count: 16))
    }

    // MARK: introduce request

    @Test func introduceRequestRoundtripsThroughJSON() throws {
        let request = PairingIntroduceRequest(
            nonce: Self.fixtureNonce(),
            clientPublicKey: Self.fixturePublicKey(byte: 0x11),
            clientDeviceID: RemoteDeviceID(value: "client-device"),
            clientKind: .iphone,
            clientDisplayName: "Ben's iPhone"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PairingIntroduceRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.version == 1)
    }

    // MARK: introduce response

    @Test func introduceResponseRoundtripsThroughJSON() throws {
        let response = PairingIntroduceResponse(
            hostPublicKey: Self.fixturePublicKey(byte: 0x22),
            expiry: Date(timeIntervalSince1970: 1_750_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PairingIntroduceResponse.self, from: data)

        #expect(decoded == response)
    }

    // MARK: await-outcome request

    @Test func awaitOutcomeRequestRoundtripsThroughJSON() throws {
        let request = PairingAwaitOutcomeRequest(nonce: Self.fixtureNonce())
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PairingAwaitOutcomeRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.version == 1)
    }

    // MARK: outcome response (all cases)

    @Test(arguments: [PairingOutcome.confirmed, .denied, .expired, .cancelled])
    func outcomeResponseRoundtripsForEveryCase(outcome: PairingOutcome) throws {
        let response = PairingOutcomeResponse(outcome: outcome)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(PairingOutcomeResponse.self, from: data)
        #expect(decoded.outcome == outcome)
    }

    // MARK: error response

    @Test func errorResponseRoundtripsForEveryCode() throws {
        let codes: [PairingErrorResponse.Code] = [
            .unsupportedVersion, .unknownNonce, .noActiveSession,
            .sessionExpired, .wrongSessionState, .internalError
        ]
        for code in codes {
            let response = PairingErrorResponse(code: code, error: "human readable: \(code.rawValue)")
            let data = try JSONEncoder().encode(response)
            let decoded = try JSONDecoder().decode(PairingErrorResponse.self, from: data)
            #expect(decoded == response, "Code \(code) did not roundtrip")
        }
    }
}
