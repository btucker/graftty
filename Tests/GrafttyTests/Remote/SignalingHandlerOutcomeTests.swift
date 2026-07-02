import CryptoKit
import Foundation
import Testing
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import WebRTC
@testable import Graftty

/// `GrafttyApp` wires `POST /v1/rtc/offer` to `WebRTCHostAgent.acceptOffer`
/// via a closure that maps a thrown error to a `WebServer.SignalingHandlerOutcome`.
/// `GrafttyApp.signalingOutcome(forAcceptOfferFailure:)` is that mapping,
/// extracted so it's testable without booting the whole app — see
/// `GrafttyApp.swift`'s `startup()` for the production call site.
@Suite("""
@spec REMOTE-11.1: If the host receives a signaling offer while another \
remote connection is active, then the application shall respond with a \
retryable unavailable status and shall not tear down the active connection.
""")
struct SignalingHandlerOutcomeTests {

    /// `WebRTCHostAgent.HostError.busy` — thrown when a second offer
    /// arrives while a negotiation is already in flight — must map to
    /// `.unavailable` (503, retryable) rather than `.internalFailure`
    /// (500), so `RemoteConnectionCoordinator` can tell "temporarily
    /// busy" apart from a real server error and fall back to `/ws`
    /// without marking the host permanently bad.
    @Test
    func busyErrorMapsToUnavailable() {
        let outcome = GrafttyApp.signalingOutcome(forAcceptOfferFailure: WebRTCHostAgent.HostError.busy)
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    /// `WebRTCHostAgent.acceptOffer`'s busy guard (`guard state == .idle
    /// || state == .closed else { throw HostError.busy }`) is the very
    /// first statement in the function — it runs before the second
    /// offer's peer connection, delegate, or state are touched. This
    /// drives a REAL `WebRTCHostAgent` into an in-flight negotiation
    /// (via a genuine SDP offer from a bare `TestOfferer`), fires a
    /// second `acceptOffer` while the first is still suspended awaiting
    /// `setRemoteDescription`, and confirms: (1) the second call is
    /// rejected with `.busy` without perturbing `state`, and (2) the
    /// FIRST negotiation still runs to completion — proof the active
    /// connection was never torn down.
    ///
    /// A full loopback (mobile `RemoteHostConnection` negotiating SSH
    /// end-to-end with this host, per `RemoteHostConnectionLoopbackTests`)
    /// isn't reachable from this mac-only target — `RemoteHostConnection`
    /// lives behind `#if canImport(UIKit)` in `GrafttyMobileKitTests`.
    /// Driving the state machine directly with a bare offerer is the
    /// honest mac-side equivalent: it exercises the actual actor
    /// reentrancy the busy guard defends against, not a mocked stand-in.
    @Test(.timeLimit(.minutes(1)))
    func busyOfferDoesNotTearDownActiveConnection() async throws {
        let agent = makeHostAgent()
        let offerer = TestOfferer()
        let offer = try await offerer.makeOffer()

        // `acceptOffer` sets `state = .answering` synchronously, before
        // its first suspension point (`setRemoteDescription`). Starting
        // it in an unstructured Task and polling for the transition —
        // rather than racing a second call in blind — makes the
        // interleaving deterministic instead of timing-dependent.
        let firstCall = Task { try await agent.acceptOffer(offer) }
        try await pollUntil(timeout: .seconds(5)) {
            await agent.state != .idle
        }
        let stateBeforeSecondOffer = await agent.state

        // The guard never inspects the offer it rejects, so a syntactically
        // empty one is enough to prove it's rejected on `state` alone.
        let secondOffer = RTCSessionDescription(type: .offer, sdp: "")
        do {
            _ = try await agent.acceptOffer(secondOffer)
            Issue.record("expected HostError.busy while a negotiation is in flight")
        } catch WebRTCHostAgent.HostError.busy {
            // expected
        }

        let stateAfterBusyRejection = await agent.state
        #expect(
            stateAfterBusyRejection == stateBeforeSecondOffer,
            "busy rejection must not perturb the in-flight negotiation's state"
        )

        let answer = try await firstCall.value
        #expect(!answer.sdp.isEmpty, "the first negotiation must still complete despite the rejected second offer")

        offerer.close()
        await agent.close()
    }

    private func makeHostAgent() -> WebRTCHostAgent {
        WebRTCHostAgent(
            hostKey: Curve25519.Signing.PrivateKey(),
            trustedPeerStore: TrustedPeerStore(directory: tempDir()),
            streamFactory: { _ in fatalError("not expected: no data channel opens in this test") },
            panesStateSubscribe: { _ in PanesStateChannelHandler.Cancellable(cancel: {}) },
            paneControlMutator: { _ in fatalError("not expected: no data channel opens in this test") },
            displayOwnershipStore: SessionDisplayOwnershipStore()
        )
    }

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-remote-11-1-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("GrafttyApp.signalingOutcome(forAcceptOfferFailure:) — maps other acceptOffer failures to internalFailure.")
struct SignalingHandlerOtherFailureTests {

    @Test
    func otherErrorsMapToInternalFailure() {
        let outcome = GrafttyApp.signalingOutcome(forAcceptOfferFailure: WebRTCHostAgent.HostError.sdpGenerationFailed)
        guard case .internalFailure = outcome else {
            Issue.record("expected .internalFailure, got \(outcome)")
            return
        }
    }
}

/// Bare WebRTC offerer: builds a peer connection, adds a data-channel
/// m-line, and produces a real SDP offer — enough for
/// `WebRTCHostAgent.acceptOffer` to run its full `setRemoteDescription`
/// → answer → `setLocalDescription` → ICE-gathering path. Deliberately
/// does not exchange ICE candidates with the host: this test only needs
/// a genuine in-flight negotiation to observe the busy guard against,
/// not end-to-end connectivity (that's covered on the mobile side by
/// `RemoteHostConnectionLoopbackTests`).
private final class TestOfferer: @unchecked Sendable {
    private let factory: RTCPeerConnectionFactory
    private let delegate = NoOpPeerConnectionDelegate()
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?

    init() {
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }

    func makeOffer() async throws -> RTCSessionDescription {
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw TestOffererError.peerConnectionInitFailed
        }
        self.peerConnection = pc
        guard let dc = pc.dataChannel(
            forLabel: GrafttyWebRTC.dataChannelLabel,
            configuration: RTCDataChannelConfiguration()
        ) else {
            throw TestOffererError.dataChannelInitFailed
        }
        self.dataChannel = dc

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: TestOffererError.sdpGenerationFailed); return }
                continuation.resume(returning: sdp)
            }
        }
    }

    func close() {
        dataChannel?.close()
        peerConnection?.close()
    }
}

private enum TestOffererError: Error {
    case peerConnectionInitFailed
    case dataChannelInitFailed
    case sdpGenerationFailed
}

private final class NoOpPeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Poll until `condition()` returns true or the deadline expires. Mirrors
/// the identically-named helper in `RemoteHostConnectionLoopbackTests`
/// (mobile target, not importable here) — used instead of an arbitrary
/// `Task.sleep` so the test exits promptly on success but still fails
/// clearly on a genuine timeout.
private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(50),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
