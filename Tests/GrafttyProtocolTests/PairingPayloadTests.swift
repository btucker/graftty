import CryptoKit
import Foundation
import Testing

@testable import GrafttyProtocol

@Suite("PairingPayload Tests")
struct PairingPayloadTests {

    // MARK: Helpers

    private func makePublicKey(byte: UInt8 = 0x01) -> RemoteIdentityPublicKey {
        try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func makePayload(
        version: Int = RemoteAccessProtocol.version,
        expiry: Date = Date(timeIntervalSince1970: 1_800_000_300),  // fixed whole-second date for deterministic round-trips
        routes: [RemoteConnectionRoute] = []
    ) -> PairingPayload {
        let pubKey = makePublicKey()
        let fingerprint = RemoteIdentityFingerprint(of: pubKey)
        return PairingPayload(
            version: version,
            hostDeviceID: RemoteDeviceID(value: "test-host-id"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: fingerprint,
            nonce: RemotePairingNonce(bytes: Data(repeating: 0xAB, count: 16)),
            expiry: expiry,
            pairingURL: URL(string: "https://hostname.local:8800/v2/pairing")!,
            routes: routes
        )
    }

    // MARK: - Round-trip

    @Test("QR encode → decodeQR produces equal payload")
    func roundTrip() throws {
        let original = makePayload()
        let qr = try original.qrEncoded()
        let decoded = try PairingPayload.decodeQR(qr)
        #expect(decoded == original)
    }

    // MARK: - QR string size

    @Test("QR string is compact (under 500 chars for a typical payload)")
    func qrStringIsCompact() throws {
        let payload = makePayload()
        let qr = try payload.qrEncoded()
        #expect(qr.count < 500, "Expected QR string under 500 chars; got \(qr.count)")
    }

    // MARK: - Prefix

    @Test("QR string starts with GRAFTTY2: prefix")
    func qrStringHasPrefix() throws {
        let qr = try makePayload().qrEncoded()
        #expect(qr.hasPrefix("GRAFTTY2:"), "Expected GRAFTTY2: prefix; got: \(qr.prefix(20))")
    }

    // MARK: - Error cases

    @Test("decodeQR without prefix throws missingPrefix")
    func missingPrefixThrows() throws {
        let payload = makePayload()
        let qr = try payload.qrEncoded()
        // Strip the prefix
        let stripped = String(qr.dropFirst("GRAFTTY2:".count))
        #expect(throws: PairingPayload.DecodeError.missingPrefix) {
            try PairingPayload.decodeQR(stripped)
        }
    }

    @Test("decodeQR with malformed base64 throws malformedBase64")
    func malformedBase64Throws() {
        // Prefix present but base64 section is garbage that can't decode
        let badInput = "GRAFTTY2:!!!not-valid-base64!!!"
        #expect(throws: PairingPayload.DecodeError.malformedBase64) {
            try PairingPayload.decodeQR(badInput)
        }
    }

    @Test("decodeQR with valid base64 but bad JSON shape throws malformedJSON")
    func malformedJSONThrows() {
        // Encode a JSON object missing all required keys as a valid base64URL string
        let jsonData = "{\"version\":2}".data(using: .utf8)!
        let encoded = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let input = "GRAFTTY2:\(encoded)"
        #expect(throws: PairingPayload.DecodeError.malformedJSON) {
            try PairingPayload.decodeQR(input)
        }
    }

    @Test("decodeQR rejects obsolete protocol versions")
    func unsupportedVersionThrows() throws {

        let payload = makePayload(version: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(payload)
        let b64 = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let input = "GRAFTTY2:\(b64)"
        #expect(throws: PairingPayload.DecodeError.unsupportedVersion(1)) {
            try PairingPayload.decodeQR(input)
        }
    }

    // MARK: - Fix 2: decodeQR must accept http(s), reject others

    @Test("decodeQR accepts http:// pairingURL (plaintext LAN pairing is authenticated by QR-pinned fingerprint + verification code)")
    func decodeQRAcceptsHttpURL() throws {
        let pubKey = makePublicKey()
        let fingerprint = RemoteIdentityFingerprint(of: pubKey)
        let plainTextPayload = PairingPayload(
            version: RemoteAccessProtocol.version,
            hostDeviceID: RemoteDeviceID(value: "test-host-id"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: fingerprint,
            nonce: RemotePairingNonce(bytes: Data(repeating: 0xAB, count: 16)),
            expiry: Date(timeIntervalSince1970: 1_800_000_300),
            pairingURL: URL(string: "http://hostname.local:8800/v2/pairing")!
        )
        let qr = try plainTextPayload.qrEncoded()
        let decoded = try PairingPayload.decodeQR(qr)
        #expect(decoded == plainTextPayload)
    }

    @Test("decodeQR accepts https:// pairingURL")
    func decodeQRAcceptsHttpsURL() throws {
        let payload = makePayload()  // makePayload already uses https://
        let qr = try payload.qrEncoded()
        let decoded = try PairingPayload.decodeQR(qr)
        #expect(decoded == payload)
    }

    @Test("decodeQR rejects non-http(s) schemes like ftp:// with insecureURL error")
    func decodeQRRejectsNonHttpScheme() throws {
        let pubKey = makePublicKey()
        let fingerprint = RemoteIdentityFingerprint(of: pubKey)
        let ftpPayload = PairingPayload(
            version: RemoteAccessProtocol.version,
            hostDeviceID: RemoteDeviceID(value: "test-host-id"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: fingerprint,
            nonce: RemotePairingNonce(bytes: Data(repeating: 0xAB, count: 16)),
            expiry: Date(timeIntervalSince1970: 1_800_000_300),
            pairingURL: URL(string: "ftp://attacker.local:21/v2/pairing")!
        )
        let qr = try ftpPayload.qrEncoded()
        #expect(throws: PairingPayload.DecodeError.insecureURL) {
            try PairingPayload.decodeQR(qr)
        }
    }

    // MARK: - routes

    @Test("QR encode → decodeQR preserves native routes")
    func roundTripPreservesRoutes() throws {
        let route = RemoteConnectionRoute(
            kind: .tailscaleDNS,
            baseURL: URL(string: "http://mac.tail1234.ts.net:8800")!
        )
        let original = makePayload(routes: [route])
        let qr = try original.qrEncoded()
        let decoded = try PairingPayload.decodeQR(qr)
        #expect(decoded == original)
        #expect(decoded.routes == [route])
    }

    @Test("decodeQR rejects a wss:// native route")
    func decodeQRRejectsWssRoute() throws {
        let route = RemoteConnectionRoute(
            kind: .tailscaleDNS,
            baseURL: URL(string: "wss://mac.tail1234.ts.net:8800")!
        )
        let payload = makePayload(routes: [route])
        let qr = try payload.qrEncoded()
        #expect(throws: PairingPayload.DecodeError.insecureURL) {
            try PairingPayload.decodeQR(qr)
        }
    }

    @Test("decodeQR rejects a file:// native route")
    func decodeQRRejectsFileRoute() throws {
        let route = RemoteConnectionRoute(
            kind: .tailscaleIP,
            baseURL: URL(string: "file:///etc/passwd")!
        )
        let payload = makePayload(routes: [route])
        let qr = try payload.qrEncoded()
        #expect(throws: PairingPayload.DecodeError.insecureURL) {
            try PairingPayload.decodeQR(qr)
        }
    }

    @Test("decodeQR rejects a javascript:// native route")
    func decodeQRRejectsJavascriptRoute() throws {
        let route = RemoteConnectionRoute(
            kind: .tailscaleIP,
            baseURL: URL(string: "javascript://alert(1)")!
        )
        let payload = makePayload(routes: [route])
        let qr = try payload.qrEncoded()
        #expect(throws: PairingPayload.DecodeError.insecureURL) {
            try PairingPayload.decodeQR(qr)
        }
    }

    @Test("payload with no routes round-trips")
    func payloadWithoutRoutesRoundTrips() throws {
        let qr = try makePayload().qrEncoded()
        let decoded = try PairingPayload.decodeQR(qr)
        #expect(decoded.routes.isEmpty)
        #expect(decoded == makePayload())
    }

    // MARK: - Codable (JSON)

    @Test("PairingPayload Codable round-trips via JSON")
    func codableRoundTrip() throws {
        let original = makePayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PairingPayload.self, from: data)
        #expect(decoded == original)
    }
}
