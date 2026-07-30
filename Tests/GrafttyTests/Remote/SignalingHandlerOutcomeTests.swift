import CryptoKit
import Foundation
import Testing
@testable import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import WebRTC
@testable import Graftty

/// The authenticated paired-access listener maps `WebRTCHostAgent`'s busy
/// error to a retryable response. The agent itself must reject that second
/// offer before touching the active connection.
@Suite("""
@spec REMOTE-11.1: If the host receives a signaling offer while another \
remote connection is active, then the application shall respond with a \
retryable unavailable status and shall not tear down the active connection.
""")
struct SignalingHandlerOutcomeTests {

    /// `WebRTCHostAgent.acceptOffer`'s busy guard (`guard state == .idle
    /// || state == .closed else { throw HostError.busy }`) is the very
    /// first statement in the function — it runs before any native
    /// WebRTC work (peer connection creation, SDP negotiation) is
    /// touched. Because the guard's decision depends on `state` alone,
    /// seeding `state` directly via the test-only `setStateForTesting`
    /// seam and observing (1) the throw and (2) `state` unchanged
    /// afterward is a faithful proof of the EARS clause "shall not tear
    /// down the active connection": the guard returns before
    /// `peerConnection`/`dataChannel` are ever touched, so there is
    /// nothing for the busy path to tear down.
    ///
    /// A prior version of this test drove a REAL negotiation (via a
    /// live or canned SDP offer) to reach `.answering`, exercising actual
    /// actor reentrancy. That made this the first mac-target test to
    /// construct a real `RTCPeerConnectionFactory`, and on headless
    /// GitHub macOS CI runners (no audio devices) libwebrtc's
    /// factory/audio-device-module init or SDP setup wedged the whole
    /// `swift test` process indefinitely (GH runs 28613078943,
    /// 28617408794) — never reproduced on a dev Mac. `WebRTCHostAgent`'s
    /// `factory` is now built lazily on first `acceptOffer` use rather
    /// than in `init` (see `WebRTCHostAgent.swift`), and this test drives
    /// the guard without ever calling `acceptOffer` successfully, so it
    /// never touches native WebRTC at all. Live end-to-end negotiation,
    /// including the busy path under real reentrancy, is still exercised
    /// by the mobile-side `RemoteHostConnectionLoopbackTests` /
    /// `SSHOverWebRTCLoopbackTests` loopback suites and W6's device smoke
    /// test.
    @Test(arguments: [WebRTCHostAgent.State.answering, .connected])
    func busyOfferDoesNotTearDownActiveConnection(activeState: WebRTCHostAgent.State) async throws {
        let agent = makeHostAgent()
        await agent.setStateForTesting(activeState)

        // The guard never inspects the offer it rejects, so a syntactically
        // empty one is enough to prove it's rejected on `state` alone.
        let offer = RTCSessionDescription(type: .offer, sdp: "")
        do {
            _ = try await agent.acceptOffer(offer)
            Issue.record("expected HostError.busy while state is \(activeState)")
        } catch WebRTCHostAgent.HostError.busy {
            // expected
        }

        let stateAfterBusyRejection = await agent.state
        #expect(
            stateAfterBusyRejection == activeState,
            "busy rejection must not perturb the active connection's state"
        )
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
