import Testing
import Foundation
import CryptoKit
@testable import GrafttyKit
import GrafttyProtocol

@Suite("HostPairingSession Tests")
struct HostPairingSessionTests {

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSession(
        identityStore: HostIdentityStore,
        peerStore: TrustedPeerStore,
        now: @escaping () -> Date = { Date() }
    ) -> HostPairingSession {
        HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: now,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v1/pairing")! }
        )
    }

    private func makeClientPublicKey(byte: UInt8 = 0xCC) -> RemoteIdentityPublicKey {
        try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    // MARK: - REMOTE-1.1: startPairing requires a host identity key

    @Test("startPairing throws noHostIdentity when identity store has no key")
    func startPairingThrowsNoHostIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        let session = makeSession(identityStore: identityStore, peerStore: peerStore)

        // No key generated — should throw
        #expect(throws: HostPairingSession.Error.noHostIdentity) {
            try session.startPairing()
        }
    }

    // MARK: - startPairing produces a valid payload

    @Test("startPairing with generated identity produces a PairingPayload whose fingerprint matches the host pubkey")
    func startPairingProducesMatchingFingerprint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)

        let privateKey = try identityStore.generateAndPersist()
        let expectedFingerprint = RemoteIdentityFingerprint(
            of: try! RemoteIdentityPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)
        )

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        let payload = try session.startPairing()

        #expect(payload.hostPublicKeyFingerprint == expectedFingerprint)
        #expect(payload.version == 1)

        if case .awaitingClient(_, _) = session.state {
            // expected
        } else {
            Issue.record("Expected awaitingClient state, got \(session.state)")
        }
    }

    // MARK: - receiveClientIdentity transitions to pendingConfirmation

    @Test("receiveClientIdentity transitions to pendingConfirmation with a verification code")
    func receiveClientIdentityTransitionsToPendingConfirmation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        let hostPrivateKey = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        let payload = try session.startPairing()

        let clientPublicKey = makeClientPublicKey()
        try session.receiveClientIdentity(
            clientPublicKey: clientPublicKey,
            clientDeviceID: .generate(),
            clientKind: .iphone,
            clientDisplayName: "My iPhone"
        )

        guard case .pendingConfirmation(_, _, _, _, let transcript, let hostCode, _) = session.state else {
            Issue.record("Expected pendingConfirmation, got \(session.state)")
            return
        }

        // Client's view of the same transcript should produce the same code.
        let hostPubKey = try! RemoteIdentityPublicKey(
            rawRepresentation: hostPrivateKey.publicKey.rawRepresentation
        )
        let clientTranscript = RemotePairingTranscript(
            hostPublicKey: hostPubKey,
            clientPublicKey: clientPublicKey,
            nonce: payload.nonce,
            expiry: transcript.expiry
        )
        let clientCode = clientTranscript.verificationCode()

        #expect(hostCode == clientCode, "Host and client verification codes must match")
        #expect(!hostCode.digits.isEmpty)
    }

    // MARK: - confirm() before receiveClientIdentity throws wrongState

    @Test("confirm() before receiveClientIdentity throws wrongState")
    func confirmBeforeReceiveThrowsWrongState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        _ = try session.startPairing()

        // Still in awaitingClient — confirm() should throw wrongState
        #expect(throws: HostPairingSession.Error.self) {
            try session.confirm()
        }
        // Peer store must remain empty
        let peers = try peerStore.list()
        #expect(peers.isEmpty, "Expected no peers inserted when confirm() is called before receiveClientIdentity")
    }

    // MARK: - REMOTE-1.2: confirm() inserts peer; deny() does not

    @Test("""
    @spec REMOTE-1.2: When a client pairs with a host, the application shall require a matching verification code and host-side confirmation before storing the client as a trusted peer.
    """)
    func remote_1_2_confirmGatesPeerInsertion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        // --- Path A: confirm() —> peer is persisted ---
        do {
            let session = makeSession(identityStore: identityStore, peerStore: peerStore)
            _ = try session.startPairing()
            let clientID = RemoteDeviceID.generate()
            try session.receiveClientIdentity(
                clientPublicKey: makeClientPublicKey(byte: 0x01),
                clientDeviceID: clientID,
                clientKind: .iphone,
                clientDisplayName: "Alice's iPhone"
            )
            let peer = try session.confirm()
            #expect(peer.displayName == "Alice's iPhone")
            let stored = try peerStore.get(id: clientID)
            #expect(stored != nil, "Peer must be in store after confirm()")
            #expect(stored?.capabilities == .defaultsAfterPairing)
        }

        // --- Path B: deny() —> peer is NOT persisted ---
        do {
            let session = makeSession(identityStore: identityStore, peerStore: peerStore)
            _ = try session.startPairing()
            let clientID = RemoteDeviceID.generate()
            try session.receiveClientIdentity(
                clientPublicKey: makeClientPublicKey(byte: 0x02),
                clientDeviceID: clientID,
                clientKind: .ipad,
                clientDisplayName: "Bob's iPad"
            )
            session.deny()
            if case .denied = session.state {
                // expected
            } else {
                Issue.record("Expected .denied state")
            }
            let stored = try peerStore.get(id: clientID)
            #expect(stored == nil, "Peer must NOT be in store after deny()")
        }
    }

    // MARK: - confirm() produces TrustedPeer with defaultsAfterPairing capabilities

    @Test("confirm() from pendingConfirmation inserts peer with defaultsAfterPairing capabilities")
    func confirmInsertsPeerWithDefaultCapabilities() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        _ = try session.startPairing()
        let clientID = RemoteDeviceID.generate()
        try session.receiveClientIdentity(
            clientPublicKey: makeClientPublicKey(),
            clientDeviceID: clientID,
            clientKind: .iphone,
            clientDisplayName: "Test iPhone"
        )
        let peer = try session.confirm()

        #expect(peer.capabilities == .defaultsAfterPairing)
        let stored = try peerStore.get(id: clientID)
        #expect(stored?.id == clientID)
        #expect(stored?.capabilities == .defaultsAfterPairing)
        if case .confirmed(let storedPeer) = session.state {
            #expect(storedPeer.id == clientID)
        } else {
            Issue.record("Expected .confirmed state")
        }
    }

    // MARK: - deny() does not insert peer; state becomes .denied

    @Test("deny() from pendingConfirmation does not insert peer; state is .denied")
    func denyDoesNotInsertPeer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        _ = try session.startPairing()
        let clientID = RemoteDeviceID.generate()
        try session.receiveClientIdentity(
            clientPublicKey: makeClientPublicKey(),
            clientDeviceID: clientID,
            clientKind: .iphone,
            clientDisplayName: "Untrusted iPhone"
        )
        session.deny()

        if case .denied = session.state {
            // expected
        } else {
            Issue.record("Expected .denied state, got \(session.state)")
        }

        let peers = try peerStore.list()
        #expect(peers.isEmpty, "No peer should be inserted after deny()")
    }

    // MARK: - Fix 3: startPairing twice generates a fresh nonce

    @Test("startPairing twice abandons prior session and generates a fresh nonce")
    func startPairingTwiceAbandonsPriorSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)

        let firstPayload = try session.startPairing()
        let secondPayload = try session.startPairing()

        #expect(firstPayload.nonce != secondPayload.nonce,
            "Second startPairing must generate a fresh nonce — old nonce is abandoned")
    }

    // MARK: - Fix 4: deny() and cancel() are no-ops from terminal states

    @Test("deny() from .confirmed state is a no-op")
    func denyIsNoOpFromConfirmed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        _ = try session.startPairing()
        let clientID = RemoteDeviceID.generate()
        try session.receiveClientIdentity(
            clientPublicKey: makeClientPublicKey(),
            clientDeviceID: clientID,
            clientKind: .iphone,
            clientDisplayName: "Test iPhone"
        )
        _ = try session.confirm()

        // Now in .confirmed — deny() must be a no-op
        session.deny()

        if case .confirmed = session.state {
            // expected
        } else {
            Issue.record("Expected .confirmed state to be preserved after deny(), got \(session.state)")
        }
    }

    @Test("cancel() from .confirmed state is a no-op")
    func cancelIsNoOpFromConfirmed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        _ = try session.startPairing()
        let clientID = RemoteDeviceID.generate()
        try session.receiveClientIdentity(
            clientPublicKey: makeClientPublicKey(),
            clientDeviceID: clientID,
            clientKind: .iphone,
            clientDisplayName: "Test iPhone"
        )
        _ = try session.confirm()

        // Now in .confirmed — cancel() must be a no-op
        session.cancel()

        if case .confirmed = session.state {
            // expected
        } else {
            Issue.record("Expected .confirmed state to be preserved after cancel(), got \(session.state)")
        }
    }

    @Test("cancel() from .denied state is a no-op")
    func cancelIsNoOpFromDenied() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        let session = makeSession(identityStore: identityStore, peerStore: peerStore)
        _ = try session.startPairing()
        let clientID = RemoteDeviceID.generate()
        try session.receiveClientIdentity(
            clientPublicKey: makeClientPublicKey(),
            clientDeviceID: clientID,
            clientKind: .iphone,
            clientDisplayName: "Test iPhone"
        )
        session.deny()

        // Now in .denied — cancel() must be a no-op
        session.cancel()

        if case .denied = session.state {
            // expected
        } else {
            Issue.record("Expected .denied state to be preserved after cancel(), got \(session.state)")
        }
    }

    // MARK: - Nonce expiry: tick() after expiry transitions to .expired

    @Test("tick() after expiry transitions from awaitingClient to expired")
    func tickExpiresAwaitingClient() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        // Clock starts before expiry
        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: { fakeNow },
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v1/pairing")! }
        )

        _ = try session.startPairing(validFor: 300)

        if case .awaitingClient = session.state {
            // expected
        } else {
            Issue.record("Expected awaitingClient")
        }

        // Advance clock past expiry
        fakeNow = fakeNow.addingTimeInterval(301)
        session.tick()

        if case .expired = session.state {
            // expected
        } else {
            Issue.record("Expected .expired state, got \(session.state)")
        }
    }

    @Test("tick() after expiry transitions from pendingConfirmation to expired")
    func tickExpiresPendingConfirmation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let identityStore = HostIdentityStore(directory: dir)
        let peerStore = TrustedPeerStore(directory: dir)
        _ = try identityStore.generateAndPersist()

        var fakeNow = Date(timeIntervalSince1970: 1_000_000)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: { fakeNow },
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v1/pairing")! }
        )

        _ = try session.startPairing(validFor: 300)
        try session.receiveClientIdentity(
            clientPublicKey: makeClientPublicKey(),
            clientDeviceID: .generate(),
            clientKind: .iphone,
            clientDisplayName: "Test iPhone"
        )

        if case .pendingConfirmation = session.state {
            // expected
        } else {
            Issue.record("Expected pendingConfirmation")
        }

        // Advance past expiry
        fakeNow = fakeNow.addingTimeInterval(301)
        session.tick()

        if case .expired = session.state {
            // expected
        } else {
            Issue.record("Expected .expired state, got \(session.state)")
        }
    }
}
