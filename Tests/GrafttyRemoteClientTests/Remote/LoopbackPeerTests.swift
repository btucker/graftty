#if os(macOS)
import CryptoKit
import Foundation
import GrafttyProtocol
import GrafttyRemoteTestSupport
import Testing
import WebRTC
@testable import GrafttyRemoteClient

/// macOS check of the shared `LoopbackPeer`, whose iOS-only callers
/// (UIKit-guarded) compile out of macOS `swift test`. On iOS CI,
/// `RemoteConnectionReconnectTests` covers the same path.
@Suite("LoopbackPeer — shared in-process WebRTC test peer", .serialized)
struct LoopbackPeerTests {
    /// `RemoteHostConnection` opens its channel as
    /// `GrafttyWebRTC.dataChannelLabel`, so an answerer opposite it must
    /// surface that channel and its inbox rather than wait for
    /// `LoopbackPeer.defaultLabel`.
    @Test(
        // Native libwebrtc stays opt-in on macOS: its worker threads can keep
        // a headless runner from exiting (see RemoteMacConnectionLoopbackTests).
        .enabled(
            if: ProcessInfo.processInfo.environment["GRAFTTY_RUN_WEBRTC_LOOPBACK"] == "1",
            "Set GRAFTTY_RUN_WEBRTC_LOOPBACK=1 to run the native WebRTC check."
        ),
        .timeLimit(.minutes(1))
    )
    func arrivedDataChannelSurfacesTheRemoteHostConnectionChannel() async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let client = RemoteHostConnection(
            clientKey: Curve25519.Signing.PrivateKey(),
            expectedHostFingerprint: RemoteIdentityFingerprint(
                of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
            )
        )
        let answerer = LoopbackPeer(role: .answerer, inbound: .keepInbox)
        let answer = try await answerer.accept(offer: try await client.createOffer())
        await client.bindIceCandidates(to: answerer)
        await answerer.bindIceCandidates(to: client)
        try await client.applyAnswer(answer)

        let (channel, _) = try await answerer.arrivedDataChannel(label: GrafttyWebRTC.dataChannelLabel)
        #expect(channel.label == GrafttyWebRTC.dataChannelLabel)

        await client.close()
        await answerer.close()
    }

    /// A blocked network (for example a host firewall holding self-addressed
    /// UDP) never opens the channel; the wait must end in a named error.
    /// `.timeLimit` cannot end it: a never-resumed continuation ignores
    /// cancellation and would hang the test process. A bare peer needs no
    /// native WebRTC threads, so this runs in ordinary macOS `swift test`.
    @Test(
        "@spec TEST-1.14: If a loopback test peer's data channel does not open or arrive within its deadline, then the test fixture shall fail the wait with a data-channel-open timeout naming the channel label.",
        .timeLimit(.minutes(1)),
        arguments: WaitKind.allCases
    )
    func waitForUnopenedChannelFailsAtItsDeadline(_ kind: WaitKind) async throws {
        let peer = LoopbackPeer(role: .answerer)
        let started = ContinuousClock.now
        await #expect(throws: LoopbackPeerError.dataChannelOpenTimedOut(label: "never-opens")) {
            switch kind {
            case .opened: _ = try await peer.openedDataChannel(label: "never-opens", timeout: .milliseconds(200))
            case .arrived: _ = try await peer.arrivedDataChannel(label: "never-opens", timeout: .milliseconds(200))
            }
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        await peer.close()
    }

    enum WaitKind: Sendable, CaseIterable { case opened, arrived }
}
#endif
