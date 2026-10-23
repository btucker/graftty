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
}
#endif
