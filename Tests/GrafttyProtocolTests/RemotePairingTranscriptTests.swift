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

    @Test("RemotePairingNonce: generate() produces at least 16 bytes")
    func generateProducesAtLeast16Bytes() {
        let nonce = RemotePairingNonce.generate()
        #expect(nonce.bytes.count >= 16)
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
            nonce: base.nonce,
            expiry: base.expiry
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
            nonce: base.nonce,
            expiry: base.expiry
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
            nonce: altNonce,
            expiry: base.expiry
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
            nonce: base.nonce,
            expiry: altExpiry
        )
        #expect(base.verificationCode() != alt.verificationCode())
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
        let nonce = RemotePairingNonce(bytes: Data(repeating: 0x03, count: 16))
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        return RemotePairingTranscript(
            hostPublicKey: hostKey,
            clientPublicKey: clientKey,
            nonce: nonce,
            expiry: expiry
        )
    }
}
