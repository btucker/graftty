import Testing
import Foundation
import CryptoKit
@testable import GrafttyProtocol

@Suite("PairingPayload Tests")
struct PairingPayloadTests {

    // MARK: Helpers

    private func makePublicKey(byte: UInt8 = 0x01) -> RemoteIdentityPublicKey {
        try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func makePayload(
        version: Int = 1,
        expiry: Date = Date(timeIntervalSince1970: 1_800_000_300),  // fixed whole-second date for deterministic round-trips
        webBaseURL: URL? = nil
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
            pairingURL: URL(string: "https://hostname.local:8800/v1/pairing")!,
            webBaseURL: webBaseURL
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

    @Test("QR string starts with GRAFTTY1: prefix")
    func qrStringHasPrefix() throws {
        let qr = try makePayload().qrEncoded()
        #expect(qr.hasPrefix("GRAFTTY1:"), "Expected GRAFTTY1: prefix; got: \(qr.prefix(20))")
    }

    // MARK: - Error cases

    @Test("decodeQR without prefix throws missingPrefix")
    func missingPrefixThrows() throws {
        let payload = makePayload()
        let qr = try payload.qrEncoded()
        // Strip the prefix
        let stripped = String(qr.dropFirst("GRAFTTY1:".count))
        #expect(throws: PairingPayload.DecodeError.missingPrefix) {
            try PairingPayload.decodeQR(stripped)
        }
    }

    @Test("decodeQR with malformed base64 throws malformedBase64")
    func malformedBase64Throws() {
        // Prefix present but base64 section is garbage that can't decode
        let badInput = "GRAFTTY1:!!!not-valid-base64!!!"
        #expect(throws: PairingPayload.DecodeError.malformedBase64) {
            try PairingPayload.decodeQR(badInput)
        }
    }

    @Test("decodeQR with valid base64 but bad JSON shape throws malformedJSON")
    func malformedJSONThrows() {
        // Encode a JSON object missing all required keys as a valid base64URL string
        let jsonData = "{\"version\":1}".data(using: .utf8)!
        let encoded = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let input = "GRAFTTY1:\(encoded)"
        #expect(throws: PairingPayload.DecodeError.malformedJSON) {
            try PairingPayload.decodeQR(input)
        }
    }

    @Test("decodeQR with version != 1 throws unsupportedVersion")
    func unsupportedVersionThrows() throws {
        // Encode a version-2 payload; the decoder should reject it.
        let payload = makePayload(version: 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(payload)
        let b64 = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let input = "GRAFTTY1:\(b64)"
        #expect(throws: PairingPayload.DecodeError.unsupportedVersion(2)) {
            try PairingPayload.decodeQR(input)
        }
    }

    // MARK: - Fix 2: decodeQR must accept http(s), reject others

    @Test("decodeQR accepts http:// pairingURL (plaintext LAN pairing is authenticated by QR-pinned fingerprint + verification code)")
    func decodeQRAcceptsHttpURL() throws {
        let pubKey = makePublicKey()
        let fingerprint = RemoteIdentityFingerprint(of: pubKey)
        let plainTextPayload = PairingPayload(
            version: 1,
            hostDeviceID: RemoteDeviceID(value: "test-host-id"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: fingerprint,
            nonce: RemotePairingNonce(bytes: Data(repeating: 0xAB, count: 16)),
            expiry: Date(timeIntervalSince1970: 1_800_000_300),
            pairingURL: URL(string: "http://hostname.local:8800/v1/pairing")!
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
            version: 1,
            hostDeviceID: RemoteDeviceID(value: "test-host-id"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: fingerprint,
            nonce: RemotePairingNonce(bytes: Data(repeating: 0xAB, count: 16)),
            expiry: Date(timeIntervalSince1970: 1_800_000_300),
            pairingURL: URL(string: "ftp://attacker.local:21/v1/pairing")!
        )
        let qr = try ftpPayload.qrEncoded()
        #expect(throws: PairingPayload.DecodeError.insecureURL) {
            try PairingPayload.decodeQR(qr)
        }
    }

    // MARK: - webBaseURL

    @Test("QR encode → decodeQR preserves webBaseURL")
    func roundTripPreservesWebBaseURL() throws {
        let webBaseURL = URL(string: "wss://mac.tail1234.ts.net:8799")!
        let original = makePayload(webBaseURL: webBaseURL)
        let qr = try original.qrEncoded()
        let decoded = try PairingPayload.decodeQR(qr)
        #expect(decoded == original)
        #expect(decoded.webBaseURL == webBaseURL)
    }

    @Test("legacy payload JSON without a webBaseURL key decodes with webBaseURL == nil")
    func legacyPayloadWithoutWebBaseURLDecodes() throws {
        // A payload encoded with webBaseURL == nil omits the key entirely,
        // producing byte-identical JSON to a payload generated before the
        // field existed — so this exercises the true legacy shape.
        let qr = try makePayload().qrEncoded()
        let b64url = String(qr.dropFirst("GRAFTTY1:".count))
        var b64 = b64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        let json = String(data: Data(base64Encoded: b64)!, encoding: .utf8)!
        #expect(!json.contains("webBaseURL"), "nil webBaseURL must be omitted so old payload JSON stays representable")

        let decoded = try PairingPayload.decodeQR(qr)
        #expect(decoded.webBaseURL == nil)
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
