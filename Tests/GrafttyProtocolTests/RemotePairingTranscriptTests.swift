import Foundation
import Testing
@testable import GrafttyProtocol

@Suite
struct RemotePairingTranscriptTests {

    // MARK: RemotePairingNonce

    @Test("RemotePairingNonce: generate() produces non-empty bytes")
    func generateProducesNonEmptyNonce() {
        let nonce = RemotePairingNonce.generate()
        #expect(!nonce.bytes.isEmpty)
    }

    @Test("RemotePairingNonce: generate() produces exactly 16 bytes")
    func generateProducesExactly16Bytes() {
        let nonce = RemotePairingNonce.generate()
        #expect(nonce.bytes.count == 16)
    }

    @Test("RemotePairingNonce: two generate() calls produce distinct nonces")
    func generateProducesUniqueNonces() {
        let a = RemotePairingNonce.generate()
        let b = RemotePairingNonce.generate()
        #expect(a != b)
    }

    @Test("RemotePairingNonce: Codable round-trips")
    func nonceCodable() throws {
        let nonce = RemotePairingNonce.generate()
        let data = try JSONEncoder().encode(nonce)
        let decoded = try JSONDecoder().decode(RemotePairingNonce.self, from: data)
        #expect(decoded == nonce)
    }

    // MARK: RemoteVerificationCode

    @Test("RemoteVerificationCode: digits is numeric-only string")
    func verificationCodeDigitsAreNumeric() throws {
        let transcript = Self.makeTranscript()
        let code = transcript.verificationCode()
        #expect(code.digits.allSatisfy { $0.isNumber })
    }

    @Test("RemoteVerificationCode: display contains a space separator")
    func verificationCodeDisplayHasSpace() throws {
        let transcript = Self.makeTranscript()
        let code = transcript.verificationCode()
        #expect(code.display.contains(" "))
    }

    @Test("RemoteVerificationCode: display is non-empty")
    func verificationCodeDisplayNonEmpty() throws {
        let transcript = Self.makeTranscript()
        let code = transcript.verificationCode()
        #expect(!code.display.isEmpty)
    }

    @Test("RemoteVerificationCode: Codable round-trips")
    func verificationCodeCodable() throws {
        let transcript = Self.makeTranscript()
        let code = transcript.verificationCode()
        let data = try JSONEncoder().encode(code)
        let decoded = try JSONDecoder().decode(RemoteVerificationCode.self, from: data)
        #expect(decoded == code)
        #expect(decoded.display == code.display)
        #expect(decoded.digits == code.digits)
    }

    // MARK: RemotePairingTranscript — verification code stability and sensitivity

    @Test("RemotePairingTranscript: verification code is stable — same inputs produce same code")
    func verificationCodeIsStable() throws {
        let transcript = Self.makeTranscript()
        let code1 = transcript.verificationCode()
        let code2 = transcript.verificationCode()
        #expect(code1 == code2)
        #expect(code1.display == code2.display)
    }

    @Test("RemotePairingTranscript: verification code changes when hostPublicKey changes")
    func verificationCodeChangesOnHostKeyChange() throws {
        let base = Self.makeTranscript()
        let altHostKey = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xFF, count: 32))
        let alt = RemotePairingTranscript(
            hostPublicKey: altHostKey,
            clientPublicKey: base.clientPublicKey,
            payload: base.payload
        )
        #expect(base.verificationCode() != alt.verificationCode())
    }

    @Test("RemotePairingTranscript: verification code changes when clientPublicKey changes")
    func verificationCodeChangesOnClientKeyChange() throws {
        let base = Self.makeTranscript()
        let altClientKey = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xEE, count: 32))
        let alt = RemotePairingTranscript(
            hostPublicKey: base.hostPublicKey,
            clientPublicKey: altClientKey,
            payload: base.payload
        )
        #expect(base.verificationCode() != alt.verificationCode())
    }

    @Test("RemotePairingTranscript: verification code changes when nonce changes")
    func verificationCodeChangesOnNonceChange() throws {
        let base = Self.makeTranscript()
        // Construct a different nonce via Codable (or direct init if accessible)
        var otherBytes = base.nonce.bytes
        otherBytes[0] ^= 0xFF  // flip first byte
        let altNonce = RemotePairingNonce(bytes: otherBytes)
        let alt = RemotePairingTranscript(
            hostPublicKey: base.hostPublicKey,
            clientPublicKey: base.clientPublicKey,
            payload: Self.makePayload(nonce: altNonce)
        )
        #expect(base.verificationCode() != alt.verificationCode())
    }

    @Test("RemotePairingTranscript: verification code changes when expiry changes")
    func verificationCodeChangesOnExpiryChange() throws {
        let base = Self.makeTranscript()
        let altExpiry = base.expiry.addingTimeInterval(60)
        let alt = RemotePairingTranscript(
            hostPublicKey: base.hostPublicKey,
            clientPublicKey: base.clientPublicKey,
            payload: Self.makePayload(expiry: altExpiry)
        )
        #expect(base.verificationCode() != alt.verificationCode())
    }

    @Test("RemotePairingTranscript: transcripts differing only in sub-second expiry produce identical verification codes and JSON")
    func expirySubSecondPrecisionIgnored() throws {
        let base = Self.makeTranscript()
        // Add 0.5 s — sub-second delta should be ignored
        let slightlyLater = RemotePairingTranscript(
            hostPublicKey: base.hostPublicKey,
            clientPublicKey: base.clientPublicKey,
            payload: Self.makePayload(expiry: base.expiry.addingTimeInterval(0.5))
        )
        #expect(base.verificationCode() == slightlyLater.verificationCode())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let baseJSON = try encoder.encode(base)
        let laterJSON = try encoder.encode(slightlyLater)
        #expect(baseJSON == laterJSON)
    }

    @Test("RemotePairingTranscript: verification code changes when persisted host metadata changes")
    func verificationCodeChangesOnHostMetadataChange() {
        let base = Self.makeTranscript()
        let altered = RemotePairingTranscript(
            hostPublicKey: base.hostPublicKey,
            clientPublicKey: base.clientPublicKey,
            payload: Self.makePayload(
                hostDeviceID: RemoteDeviceID(value: "substituted-host"),
                hostDisplayName: "Substituted Mac"
            )
        )

        #expect(base.verificationCode() != altered.verificationCode())
    }

    @Test("RemotePairingTranscript: verification code changes when a connection route changes")
    func verificationCodeChangesOnRouteChange() {
        let base = Self.makeTranscript()
        let altered = RemotePairingTranscript(
            hostPublicKey: base.hostPublicKey,
            clientPublicKey: base.clientPublicKey,
            payload: Self.makePayload(routes: [
                RemoteConnectionRoute(
                    kind: .tailscaleDNS,
                    baseURL: URL(string: "http://attacker.tailnet.ts.net:8800")!
                )
            ])
        )

        #expect(base.verificationCode() != altered.verificationCode())
    }

    @Test("RemotePairingTranscript: Codable round-trips")
    func transcriptCodable() throws {
        let transcript = Self.makeTranscript()
        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(RemotePairingTranscript.self, from: data)
        #expect(decoded == transcript)
        #expect(decoded.verificationCode() == transcript.verificationCode())
    }

    // MARK: Helpers

    private static func makeTranscript() -> RemotePairingTranscript {
        let hostKey = try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0x01, count: 32))
        let clientKey = try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0x02, count: 32))
        return RemotePairingTranscript(
            hostPublicKey: hostKey,
            clientPublicKey: clientKey,
            payload: makePayload()
        )
    }

    private static func makePayload(
        nonce: RemotePairingNonce = RemotePairingNonce(
            bytes: Data(repeating: 0x03, count: 16)
        ),
        expiry: Date = Date(timeIntervalSince1970: 1_700_000_000),
        hostDeviceID: RemoteDeviceID = RemoteDeviceID(value: "host-1"),
        hostDisplayName: String = "Studio Mac",
        routes: [RemoteConnectionRoute] = [
            RemoteConnectionRoute(
                kind: .lan,
                baseURL: URL(string: "http://studio.local:8800")!
            )
        ]
    ) -> PairingPayload {
        let hostKey = try! RemoteIdentityPublicKey(
            rawRepresentation: Data(repeating: 0x01, count: 32)
        )
        return PairingPayload(
            hostDeviceID: hostDeviceID,
            hostKind: .mac,
            hostDisplayName: hostDisplayName,
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(of: hostKey),
            nonce: nonce,
            expiry: expiry,
            pairingURL: URL(string: "http://studio.local:8800/v2/pairing")!,
            routes: routes
        )
    }
}
