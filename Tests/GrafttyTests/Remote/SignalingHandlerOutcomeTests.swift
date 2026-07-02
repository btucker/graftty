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
    /// (via a genuine, statically-canned SDP offer — see
    /// `cannedDataChannelOffer` below), fires a second `acceptOffer`
    /// while the first is still suspended awaiting `setRemoteDescription`,
    /// and confirms: (1) the second call is rejected with `.busy` without
    /// perturbing `state`, and (2) the FIRST negotiation still runs to
    /// completion — proof the active connection was never torn down.
    ///
    /// A full loopback (mobile `RemoteHostConnection` negotiating SSH
    /// end-to-end with this host, per `RemoteHostConnectionLoopbackTests`)
    /// isn't reachable from this mac-only target — `RemoteHostConnection`
    /// lives behind `#if canImport(UIKit)` in `GrafttyMobileKitTests`.
    /// Driving the state machine directly with a real agent and a real
    /// (but canned) offer is the honest mac-side equivalent: it exercises
    /// the actual actor reentrancy the busy guard defends against, not a
    /// mocked stand-in for `WebRTCHostAgent` itself.
    ///
    /// The offer used to come from a second live `RTCPeerConnectionFactory`
    /// (a bare `TestOfferer`) constructed fresh in-process for every test
    /// run. That doubled the number of concurrent native WebRTC peer
    /// connections/threads this single test spun up on the macOS CI
    /// runner — the first time any test in the mac target touched real
    /// WebRTC at all — and CI (unlike every local run) hung indefinitely
    /// partway through it (GH run 28613078943, twice identically), with
    /// no further test output for 5 minutes until the job was killed.
    /// `TestOfferer.makeOffer()`'s `pc.offer(for:)` completion had no
    /// timeout of its own (unlike `acceptOffer`'s bounded ICE-gathering
    /// wait), so any native stall there — plausible on a constrained,
    /// sandboxed CI runner — had no fallback. The busy guard doesn't care
    /// where the offer came from or whether it's answerable end-to-end
    /// (`acceptOffer` never inspects the *second* offer's contents, and
    /// the first offer only needs to be a syntactically valid SDP that
    /// `setRemoteDescription` accepts), so a canned offer captured from a
    /// real offerer keeps `acceptOffer`'s real negotiation path exercised
    /// while removing the one truly unbounded, CI-fragile wait and halving
    /// the live native WebRTC surface this test touches.
    @Test(.timeLimit(.minutes(1)))
    func busyOfferDoesNotTearDownActiveConnection() async throws {
        let agent = makeHostAgent()
        let offer = RTCSessionDescription(type: .offer, sdp: Self.cannedDataChannelOffer)

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

        await agent.close()
    }

    /// A genuine unified-plan, data-channel-only SDP offer — one real
    /// `m=application ... webrtc-datachannel` line, ICE credentials, and a
    /// DTLS fingerprint — captured once from a live `RTCPeerConnectionFactory`
    /// offerer (the same shape `TestOfferer` used to produce). `acceptOffer`
    /// only needs `setRemoteDescription` to accept a syntactically valid
    /// offer; it doesn't validate that the ICE credentials or fingerprint
    /// belong to a reachable peer, so a static capture is exactly as real a
    /// negotiation partner as a live one for this test's purposes, without
    /// spinning up a second native peer connection on every run.
    private static let cannedDataChannelOffer = """
        v=0
        o=- 7997775182317506662 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0
        a=extmap-allow-mixed
        a=msid-semantic: WMS
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        c=IN IP4 0.0.0.0
        a=ice-ufrag:+alb
        a=ice-pwd:xJn1X85r0MRvLKE/Ulm6YOrt
        a=ice-options:trickle renomination
        a=fingerprint:sha-256 47:FD:2F:76:D1:FC:CF:99:A6:4B:3B:2E:21:AA:24:30:B1:D0:5C:35:62:9B:66:72:AC:67:54:EE:F4:68:BB:9C
        a=setup:actpass
        a=mid:0
        a=sctp-port:5000
        a=max-message-size:262144

        """

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
