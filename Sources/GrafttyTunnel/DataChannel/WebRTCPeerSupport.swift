#if canImport(WebRTC)
import Foundation
import WebRTC

/// Peer-connection plumbing shared by the host agent (`WebRTCHostAgent`,
/// the answerer) and the remote client (`RemoteHostConnection`, the
/// offerer).
public enum WebRTCPeerSupport {
    /// `RTCInitializeSSL` is process-wide and not refcounted in every SDK
    /// build, so a per-instance `deinit { RTCCleanupSSL() }` would tear SSL
    /// down for other live connections. A one-shot static token initialises
    /// once and never cleans up; this matches what production iOS apps
    /// using WebRTC.framework typically do.
    private static let sslInitOnce: Void = { RTCInitializeSSL() }()

    public static func initializeSSL() { _ = sslInitOnce }

    /// The baseline peer-connection configuration both peers use.
    public static func defaultConfig() -> RTCConfiguration {
        let config = RTCConfiguration()
        // Empty ICE servers — LAN / Tailscale loopback uses mDNS-derived
        // host candidates only; no STUN/TURN needed.
        config.iceServers = []
        config.iceTransportPolicy = .all
        config.candidateNetworkPolicy = .all
        config.maxIPv6Networks = .max
        config.sdpSemantics = .unifiedPlan
        // Signaling is non-trickle: the only candidates the remote peer
        // receives are bundled into the initial offer or answer SDP.
        // Continual gathering keeps `iceGatheringState` from completing, so
        // offer and answer generation otherwise pay their five-second
        // fallback. Network-interface changes after negotiation require a
        // fresh connection under this policy.
        config.continualGatheringPolicy = .gatherOnce
        return config
    }

    public static func setLocalDescription(
        _ pc: RTCPeerConnection,
        _ sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }

    public static func setRemoteDescription(
        _ pc: RTCPeerConnection,
        _ sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }
}

/// Delegate adapter that bridges WebRTC's NSObject-callback world to
/// Swift closures the owning actor sets and reads. WebRTC's SDK
/// dispatches every delegate call for a given peer connection on a
/// fixed internal queue, so the closure properties are read serially —
/// `nonisolated(unsafe)` marks the deliberate sharing across that
/// boundary, while `@Sendable` on the closure type prevents callers
/// from capturing non-Sendable actor state by accident.
///
/// Callbacks carry the source peer connection's `ObjectIdentifier` so an
/// owner that replaces its peer connection can ignore stale events.
public final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    public nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    /// Fired for each remotely created data channel, with a
    /// `DataChannelInbox` already attached as its delegate.
    public nonisolated(unsafe) var onDataChannel: (@Sendable (
        ObjectIdentifier,
        RTCDataChannel,
        DataChannelInbox
    ) -> Void)?
    /// The trailing `UInt64` increases with every ICE state event so an
    /// owner can discard callbacks that arrive out of order.
    public nonisolated(unsafe) var onIceStateChange: (@Sendable (
        ObjectIdentifier,
        RTCIceConnectionState,
        UInt64
    ) -> Void)?
    public nonisolated(unsafe) var onIceGatheringComplete: (@Sendable (ObjectIdentifier) -> Void)?

    private let iceEventSequenceLock = NSLock()
    private var iceEventSequence: UInt64 = 0

    public override init() {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let sequence = iceEventSequenceLock.withLock {
            iceEventSequence &+= 1
            return iceEventSequence
        }
        onIceStateChange?(ObjectIdentifier(peerConnection), newState, sequence)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onIceGatheringComplete?(ObjectIdentifier(peerConnection))
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // WebRTC serializes message delivery behind this callback. Attach
        // the inbox before returning so the owner's actor hop cannot lose
        // bytes.
        let inbox = DataChannelInbox()
        dataChannel.delegate = inbox
        onDataChannel?(ObjectIdentifier(peerConnection), dataChannel, inbox)
    }
}

#endif
