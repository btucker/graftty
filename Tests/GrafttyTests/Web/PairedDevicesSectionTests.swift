import Testing
import Foundation
import GrafttyKit
import GrafttyProtocol
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
            pairingURL: URL(string: "http://127.0.0.1:8080/v1/pairing")!
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
        let transcript = RemotePairingTranscript(
            hostPublicKey: Self.hostPublicKey,
            clientPublicKey: Self.clientPublicKey,
            nonce: RemotePairingNonce(bytes: Data(repeating: 0x02, count: 16)),
            expiry: Date(timeIntervalSince1970: 2000)
        )
        let code = transcript.verificationCode()
        let state = HostPairingSessionState.pendingConfirmation(
            clientPublicKey: Self.clientPublicKey,
            clientDeviceID: RemoteDeviceID(value: "client-1"),
            clientKind: .iphone,
            clientDisplayName: "Ben's iPhone",
            transcript: transcript,
            verificationCode: code,
            expiry: Date(timeIntervalSince1970: 2000)
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
