import Foundation
import GrafttyKit
import GrafttyProtocol
import Testing

@testable import Graftty

// MARK: - PairingCountdownFormatter

@Suite("PairingCountdownFormatter Tests")
struct PairingCountdownFormatterTests {

    @Test("formats whole minutes and seconds as m:ss")
    func formatsMinutesAndSeconds() {
        let now = Date(timeIntervalSince1970: 0)
        let expiry = now.addingTimeInterval(272) // 4m32s
        #expect(PairingCountdownFormatter.remainingLabel(untilExpiry: expiry, now: now) == "4:32")
    }

    @Test("pads seconds under ten with a leading zero")
    func padsSeconds() {
        let now = Date(timeIntervalSince1970: 0)
        let expiry = now.addingTimeInterval(65) // 1m05s
        #expect(PairingCountdownFormatter.remainingLabel(untilExpiry: expiry, now: now) == "1:05")
    }

    @Test("clamps to 0:00 once expiry has passed rather than going negative")
    func clampsToZeroAfterExpiry() {
        let now = Date(timeIntervalSince1970: 100)
        let expiry = Date(timeIntervalSince1970: 40)
        #expect(PairingCountdownFormatter.remainingLabel(untilExpiry: expiry, now: now) == "0:00")
    }
}

// MARK: - RemoteDeviceKind.displayLabel

@Suite("RemoteDeviceKind displayLabel Tests")
struct RemoteDeviceKindDisplayLabelTests {

    @Test("maps every kind to its human-readable label", arguments: [
        (RemoteDeviceKind.mac, "Mac"),
        (RemoteDeviceKind.iphone, "iPhone"),
        (RemoteDeviceKind.ipad, "iPad"),
    ])
    func mapsKindToLabel(kind: RemoteDeviceKind, expected: String) {
        #expect(kind.displayLabel == expected)
    }
}

// MARK: - PairingSectionDisplay.mapping

@Suite("PairingSectionDisplay mapping Tests")
struct PairingSectionDisplayMappingTests {

    private static let hostDeviceID = RemoteDeviceID(value: "host-1")
    private static let hostPublicKey = try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
    private static let clientPublicKey = try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xBB, count: 32))

    private static func makePayload(expiry: Date) -> PairingPayload {
        PairingPayload(
            hostDeviceID: hostDeviceID,
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(of: hostPublicKey),
            nonce: RemotePairingNonce(bytes: Data(repeating: 0x01, count: 16)),
            expiry: expiry,
            pairingURL: URL(string: "http://127.0.0.1:8080/v2/pairing")!
        )
    }

    @Test("idle state maps to .idle")
    func idleMapsToIdle() {
        #expect(PairingSectionDisplay.mapping(for: .idle) == .idle)
    }

    @Test("cancelled state maps to .idle so the settings pane looks unchanged after a user-initiated cancel")
    func cancelledMapsToIdle() {
        #expect(PairingSectionDisplay.mapping(for: .cancelled) == .idle)
    }

    @Test("awaitingClient carries the payload and expiry through unchanged")
    func awaitingClientCarriesPayloadAndExpiry() {
        let expiry = Date(timeIntervalSince1970: 1000)
        let payload = Self.makePayload(expiry: expiry)
        #expect(
            PairingSectionDisplay.mapping(for: .awaitingClient(payload: payload, expiry: expiry))
                == .awaitingClient(payload: payload, expiry: expiry)
        )
    }

    @Test("pendingConfirmation surfaces the client's display name, kind, and verification code")
    func pendingConfirmationSurfacesClientDetails() {
        let expiry = Date(timeIntervalSince1970: 2000)
        let transcript = RemotePairingTranscript(
            hostPublicKey: Self.hostPublicKey,
            clientPublicKey: Self.clientPublicKey,
            payload: Self.makePayload(expiry: expiry)
        )
        let code = transcript.verificationCode()
        let state = HostPairingSessionState.pendingConfirmation(
            clientPublicKey: Self.clientPublicKey,
            clientDeviceID: RemoteDeviceID(value: "client-1"),
            clientKind: .iphone,
            clientDisplayName: "Ben's iPhone",
            transcript: transcript,
            verificationCode: code,
            expiry: expiry
        )
        #expect(
            PairingSectionDisplay.mapping(for: state)
                == .pendingConfirmation(clientDisplayName: "Ben's iPhone", clientKind: .iphone, verificationCode: code)
        )
    }

    @Test("confirmed surfaces the persisted peer's display name")
    func confirmedSurfacesPeerDisplayName() {
        let peer = TrustedPeer(
            id: RemoteDeviceID(value: "client-1"),
            kind: .iphone,
            publicKey: Self.clientPublicKey,
            displayName: "Ben's iPhone",
            capabilities: .defaultsAfterPairing,
            pairedAt: Date(timeIntervalSince1970: 3000),
            lastSeenAt: nil
        )
        #expect(
            PairingSectionDisplay.mapping(for: .confirmed(trustedPeer: peer))
                == .confirmedSuccess(peerDisplayName: "Ben's iPhone")
        )
    }

    @Test("denied, expired, and failed each map to a distinct terminal message")
    func terminalStatesMapToMessages() {
        guard case .terminalMessage = PairingSectionDisplay.mapping(for: .denied) else {
            Issue.record("Expected .terminalMessage for .denied")
            return
        }
        guard case .terminalMessage = PairingSectionDisplay.mapping(for: .expired) else {
            Issue.record("Expected .terminalMessage for .expired")
            return
        }
        #expect(
            PairingSectionDisplay.mapping(for: .failed(message: "boom"))
                == .terminalMessage("boom")
        )
    }
}

// MARK: - PairedDevicesSection.performRemove

/// Collects the device IDs passed to a spy `revoke` closure. An actor
/// (rather than a plain class) since `performRemove` awaits the closure
/// from an async context and Swift Testing runs `@Test func` bodies
/// concurrently with other tests.
private actor RevokeSpy {
    private(set) var revokedIDs: [RemoteDeviceID] = []
    func revoke(_ id: RemoteDeviceID) {
        revokedIDs.append(id)
    }
}

/// @spec REMOTE-3.3: When a host operator removes a paired device from
/// Settings, the application shall close that device's live session
/// immediately rather than waiting for its next attach attempt to fail,
/// and shall not close any session if the device could not be removed
/// from the trust store.
@Suite("PairedDevicesSection.performRemove Tests")
struct PairedDevicesSectionPerformRemoveTests {

    private static func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-paired-devices-remove-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makePeer(id: RemoteDeviceID) -> TrustedPeer {
        TrustedPeer(
            id: id,
            kind: .iphone,
            publicKey: try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xCC, count: 32)),
            displayName: "Ben's iPhone",
            capabilities: .defaultsAfterPairing,
            pairedAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: nil
        )
    }

    @Test("on a successful store removal, revokes the peer's live connection AFTER it leaves the store")
    func revokesAfterSuccessfulRemoval() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let peerID = RemoteDeviceID(value: "peer-1")
        try store.add(Self.makePeer(id: peerID))
        let spy = RevokeSpy()

        let error = await PairedDevicesSection.performRemove(
            peerID: peerID,
            store: store,
            revoke: { await spy.revoke($0) }
        )

        #expect(error == nil)
        #expect(try store.list().isEmpty)
        let revokedIDs = await spy.revokedIDs
        #expect(revokedIDs == [peerID])
    }

    @Test("when the store fails to remove the peer, does NOT revoke — the peer is still considered paired")
    func doesNotRevokeWhenStoreRemoveFails() async throws {
        let store = TrustedPeerStore(directory: Self.tempDir())
        let peerID = RemoteDeviceID(value: "never-added")
        let spy = RevokeSpy()

        let error = await PairedDevicesSection.performRemove(
            peerID: peerID,
            store: store,
            revoke: { await spy.revoke($0) }
        )

        #expect(error != nil)
        let revokedIDs = await spy.revokedIDs
        #expect(revokedIDs.isEmpty)
    }
}
