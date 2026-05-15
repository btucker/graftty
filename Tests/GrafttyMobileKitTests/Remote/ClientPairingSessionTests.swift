import Testing
import Foundation
import CryptoKit

#if canImport(UIKit)
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite("ClientPairingSession Tests")
struct ClientPairingSessionTests {

    // MARK: Helpers

    func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    func makePublicKey(byte: UInt8) -> RemoteIdentityPublicKey {
        try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    func makeSession(
        identityStore: ClientIdentityStore,
        pinnedHostStore: PinnedHostStore,
        now: @escaping () -> Date = { Date() }
    ) -> ClientPairingSession {
        ClientPairingSession(
            identityStore: identityStore,
            pinnedHostStore: pinnedHostStore,
            now: now,
            clientDeviceID: .generate(),
            clientKind: .iphone,
            clientDisplayName: "Test iPhone"
        )
    }

    func makePayload(
        hostPublicKey: RemoteIdentityPublicKey,
        expiry: Date = Date(timeIntervalSince1970: 1_800_000_300)
    ) -> PairingPayload {
        let fingerprint = RemoteIdentityFingerprint(of: hostPublicKey)
        return PairingPayload(
            version: 1,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: fingerprint,
            nonce: RemotePairingNonce.generate(),
            expiry: expiry,
            pairingURL: URL(string: "https://host.local:8800/v1/pairing")!
        )
    }

    // MARK: - consume(payload:) with valid payload transitions to readyToConnect

    @Test("consume(payload:) with valid payload transitions to readyToConnect")
    func consumeValidPayloadTransitionsToReadyToConnect() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        let hostPublicKey = makePublicKey(byte: 0x01)
        let payload = makePayload(hostPublicKey: hostPublicKey)
        try session.consume(payload: payload)

        if case .readyToConnect(let p) = session.state {
            #expect(p.hostDeviceID == payload.hostDeviceID)
        } else {
            Issue.record("Expected readyToConnect, got \(session.state)")
        }
    }

    // MARK: - consume(payload:) rejects unsupported version

    @Test("consume(payload:) rejects unsupported version with unsupportedPayloadVersion")
    func consumeRejectsUnsupportedVersion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        let hostPublicKey = makePublicKey(byte: 0x01)
        let fingerprint = RemoteIdentityFingerprint(of: hostPublicKey)
        let v2Payload = PairingPayload(
            version: 2,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: fingerprint,
            nonce: RemotePairingNonce.generate(),
            expiry: Date(timeIntervalSince1970: 1_800_000_300),
            pairingURL: URL(string: "https://host.local:8800/v1/pairing")!
        )

        #expect(throws: ClientPairingSession.Error.unsupportedPayloadVersion(2)) {
            try session.consume(payload: v2Payload)
        }
    }

    // MARK: - consume(payload:) rejects expired payload

    @Test("consume(payload:) rejects expired payload with expired error")
    func consumeRejectsExpiredPayload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        let pinnedHostStore = PinnedHostStore(directory: dir)
        // Clock is after the expiry
        let session = makeSession(
            identityStore: identityStore,
            pinnedHostStore: pinnedHostStore,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )

        let hostPublicKey = makePublicKey(byte: 0x01)
        let expiredPayload = makePayload(
            hostPublicKey: hostPublicKey,
            expiry: Date(timeIntervalSince1970: 1_800_000_300)  // in the past relative to now
        )

        #expect(throws: ClientPairingSession.Error.expired) {
            try session.consume(payload: expiredPayload)
        }

        if case .expired = session.state {
            // expected
        } else {
            Issue.record("Expected .expired state, got \(session.state)")
        }
    }

    // MARK: - confirm(hostPublicKey:) with matching fingerprint persists PinnedHost

    @Test("confirm(hostPublicKey:) with matching fingerprint persists a PinnedHost")
    func confirmWithMatchingFingerprintPersistsPinnedHost() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        // Use a real private key so the public key round-trips correctly
        let hostPrivateKey = makePrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: hostPrivateKey.publicKey.rawRepresentation)
        let payload = makePayload(hostPublicKey: hostPublicKey)

        try session.consume(payload: payload)

        // Build transcript (normally done by the network layer after POST)
        let clientPublicKey = try identityStore.currentPublicKey()!
        let transcript = RemotePairingTranscript(
            hostPublicKey: hostPublicKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: payload.expiry
        )
        try session.markAwaitingConfirmation(transcript: transcript)

        // Host confirms and sends back its full public key
        let pinnedHost = try session.confirm(hostPublicKey: hostPublicKey)
        #expect(pinnedHost.displayName == "Test Mac")

        if case .confirmed(let h) = session.state {
            #expect(h.id == payload.hostDeviceID)
        } else {
            Issue.record("Expected .confirmed state, got \(session.state)")
        }

        // Verify persisted
        let stored = try pinnedHostStore.get(id: payload.hostDeviceID)
        #expect(stored != nil, "Host must be persisted after confirm()")
    }

    // MARK: - Fingerprint mismatch (client-side REMOTE-1.2 enforcement)

    @Test("confirm(hostPublicKey:) with fingerprint mismatch throws fingerprintMismatch and does not pin the host")
    func fingerprintMismatchDoesNotPin() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        // The QR payload has fingerprint of hostPublicKey
        let hostPrivateKey = makePrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: hostPrivateKey.publicKey.rawRepresentation)
        let payload = makePayload(hostPublicKey: hostPublicKey)

        try session.consume(payload: payload)

        let clientPublicKey = try identityStore.currentPublicKey()!
        let transcript = RemotePairingTranscript(
            hostPublicKey: hostPublicKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: payload.expiry
        )
        try session.markAwaitingConfirmation(transcript: transcript)

        // Attacker substitutes a different key
        let impostorKey = makePublicKey(byte: 0xFF)
        #expect(throws: ClientPairingSession.Error.fingerprintMismatch) {
            try session.confirm(hostPublicKey: impostorKey)
        }

        // Nothing should be pinned
        let list = try pinnedHostStore.list()
        #expect(list.isEmpty, "Expected no hosts pinned after fingerprint mismatch")
    }

    // MARK: - Fix 1: fingerprintMismatch must terminate session (security)

    @Test("confirm(hostPublicKey:) with fingerprint mismatch transitions to .failed, not awaitingHostConfirmation")
    func fingerprintMismatchTerminatesSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        let hostPrivateKey = makePrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: hostPrivateKey.publicKey.rawRepresentation)
        let payload = makePayload(hostPublicKey: hostPublicKey)

        try session.consume(payload: payload)

        let clientPublicKey = try identityStore.currentPublicKey()!
        let transcript = RemotePairingTranscript(
            hostPublicKey: hostPublicKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: payload.expiry
        )
        try session.markAwaitingConfirmation(transcript: transcript)

        // Attacker substitutes a different key
        let impostorKey = makePublicKey(byte: 0xFF)
        #expect(throws: ClientPairingSession.Error.fingerprintMismatch) {
            try session.confirm(hostPublicKey: impostorKey)
        }

        // Session must be in a terminal .failed state — not .awaitingHostConfirmation
        if case .failed = session.state {
            // expected — MITM retry window is closed
        } else {
            Issue.record("Expected .failed state after fingerprint mismatch, got \(session.state)")
        }
    }

    // MARK: - Fix 4: deny/cancel/handleDenied/cancel are no-ops from terminal states

    @Test("handleDenied() from .confirmed state is a no-op")
    func handleDeniedIsNoOpFromConfirmed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        let hostPrivateKey = makePrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: hostPrivateKey.publicKey.rawRepresentation)
        let payload = makePayload(hostPublicKey: hostPublicKey)

        try session.consume(payload: payload)
        let clientPublicKey = try identityStore.currentPublicKey()!
        let transcript = RemotePairingTranscript(
            hostPublicKey: hostPublicKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: payload.expiry
        )
        try session.markAwaitingConfirmation(transcript: transcript)
        _ = try session.confirm(hostPublicKey: hostPublicKey)

        // Now in .confirmed — handleDenied must be a no-op
        session.handleDenied()

        if case .confirmed = session.state {
            // expected — confirmed is unchanged
        } else {
            Issue.record("Expected .confirmed state to be preserved after handleDenied(), got \(session.state)")
        }
    }

    @Test("cancel() from .confirmed state is a no-op")
    func cancelIsNoOpFromConfirmed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        let hostPrivateKey = makePrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: hostPrivateKey.publicKey.rawRepresentation)
        let payload = makePayload(hostPublicKey: hostPublicKey)

        try session.consume(payload: payload)
        let clientPublicKey = try identityStore.currentPublicKey()!
        let transcript = RemotePairingTranscript(
            hostPublicKey: hostPublicKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: payload.expiry
        )
        try session.markAwaitingConfirmation(transcript: transcript)
        _ = try session.confirm(hostPublicKey: hostPublicKey)

        // Now in .confirmed — cancel() must be a no-op
        session.cancel()

        if case .confirmed = session.state {
            // expected — confirmed is unchanged
        } else {
            Issue.record("Expected .confirmed state to be preserved after cancel(), got \(session.state)")
        }
    }

    // MARK: - handleDenied() transitions to .denied

    @Test("handleDenied() transitions to denied state")
    func handleDeniedTransitionsToDenied() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = ClientIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let pinnedHostStore = PinnedHostStore(directory: dir)
        let session = makeSession(identityStore: identityStore, pinnedHostStore: pinnedHostStore)

        let hostPublicKey = makePublicKey(byte: 0x01)
        let payload = makePayload(hostPublicKey: hostPublicKey)
        try session.consume(payload: payload)

        let clientPublicKey = try identityStore.currentPublicKey()!
        let transcript = RemotePairingTranscript(
            hostPublicKey: hostPublicKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: payload.expiry
        )
        try session.markAwaitingConfirmation(transcript: transcript)

        session.handleDenied()

        if case .denied = session.state {
            // expected
        } else {
            Issue.record("Expected .denied state, got \(session.state)")
        }
    }
}
#endif
