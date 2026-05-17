#if canImport(UIKit)
import Foundation
import WebRTC

/// Common interface for "thing that can accept ICE candidates from a
/// peer." Used by the loopback test to wire ICE both directions
/// without a signaling endpoint. Real signaling (M1.2) replaces this.
public protocol WebRTCIceCandidateReceiver: Sendable {
    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws
}

/// Mobile-side actor that owns a single `RTCPeerConnection` to a paired
/// host plus its DataChannel.
///
/// This is the scaffold per the [iPad layout design doc](../../../docs/superpowers/specs/2026-05-15-ipad-layout-design.md)
/// §6.1. Subsequent PRs add: signaling exchange (M1.2), Noise handshake
/// over the DataChannel (M1.3), and the channel-framing layer (M1.4)
/// that multiplexes terminal / panes_state / pane_control traffic.
///
/// The instance is per-host: one `RemoteHostConnection` exists per
/// host the user has open in the iPad layout. Host switching tears
/// the current connection down and builds a fresh one.
public actor RemoteHostConnection: WebRTCIceCandidateReceiver {

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case failed(reason: String)
        case closed
    }

    public private(set) var state: State = .idle

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    /// `nonisolated let` so the `nonisolated` `bindIceCandidates`
    /// can install its callback without crossing the actor boundary.
    /// The delegate classes are `@unchecked Sendable`; their mutable
    /// closure properties carry `nonisolated(unsafe) @Sendable` and
    /// are themselves the explicit synchronization contract with
    /// WebRTC's internal dispatch queue.
    private nonisolated let delegate: PeerConnectionDelegate
    private nonisolated let dataChannelDelegate: DataChannelDelegate

    /// Continuation that resumes when the data channel transitions to
    /// `open`. Set during `connect`, resumed by `dataChannelDidChangeState`.
    private var openContinuation: CheckedContinuation<Void, Error>?

    /// Most-recently received binary frame. Test-only entry point —
    /// production code routes through the channel-framing layer
    /// added in a later PR. `internal` so the in-target test can read it
    /// via `@testable import`.
    internal private(set) var lastReceivedBinary: Data?

    /// SSH-style label of the single multiplexing DataChannel between
    /// client and host. Both sides need to agree; promoted from a
    /// magic string to a named constant so M1.2 signaling can refer
    /// to it by symbol.
    public static let dataChannelLabel = "graftty"

    public init() {
        // SSL and codec subsystems are process-wide; initialize once.
        Self.initializeWebRTC()
        // nil factories: DataChannel-only — no video codec work needed.
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        self.delegate = PeerConnectionDelegate()
        self.dataChannelDelegate = DataChannelDelegate()
    }

    /// Build the local peer connection and create the data channel.
    /// Returns the local SDP offer for signaling-side hand-off.
    public func createOffer() async throws -> RTCSessionDescription {
        let config = Self.defaultConfig()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw ConnectionError.peerConnectionInitFailed
        }
        self.peerConnection = pc

        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        guard let dc = pc.dataChannel(
            forLabel: Self.dataChannelLabel,
            configuration: dataChannelConfig
        ) else {
            throw ConnectionError.dataChannelInitFailed
        }
        dc.delegate = dataChannelDelegate
        self.dataChannel = dc

        state = .connecting

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: ConnectionError.sdpGenerationFailed); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, offer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? offer
    }

    /// See `WebRTCHostAgent.waitForIceGatheringComplete` for the rationale.
    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onIceGatheringComplete = {
                continuation.resume()
            }
            if pc.iceGatheringState == .complete {
                delegate.onIceGatheringComplete = nil
                continuation.resume()
            }
        }
        delegate.onIceGatheringComplete = nil
    }

    /// Apply the answer received from the remote host and return when
    /// the data channel is open (or throw on failure / timeout).
    public func applyAnswer(_ answer: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { throw ConnectionError.notConfigured }
        try await Self.setRemoteDescription(pc, answer)
        try await waitForDataChannelOpen()
    }

    /// Send a binary frame over the open data channel. Throws if the
    /// channel isn't open. Production code will route through a channel
    /// multiplexer; this is the raw-bytes entry point for the loopback test.
    public func sendBinary(_ data: Data) async throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw ConnectionError.notOpen
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else {
            throw ConnectionError.sendFailed
        }
    }

    /// Bind locally-gathered ICE candidates so they're routed into the
    /// peer's connection. Used by the M1.1 loopback test that bypasses
    /// the signaling endpoint. Real signaling lands in M1.2.
    nonisolated public func bindIceCandidates(to peer: WebRTCIceCandidateReceiver) {
        delegate.onIceCandidate = { candidate in
            Task { try? await peer.addRemoteIceCandidate(candidate) }
        }
    }

    /// Apply an ICE candidate received from the remote peer.
    public func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { throw ConnectionError.notConfigured }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }

    private func recordReceivedBinary(_ data: Data) {
        lastReceivedBinary = data
    }

    public func close() {
        if let pending = openContinuation {
            openContinuation = nil
            pending.resume(throwing: ConnectionError.closed)
        }
        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        state = .closed
    }

    private func waitForDataChannelOpen() async throws {
        if dataChannel?.readyState == .open {
            state = .connected
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.openContinuation = continuation
            self.dataChannelDelegate.onOpen = { [weak self] in
                Task { await self?.handleDataChannelOpen() }
            }
            self.dataChannelDelegate.onMessage = { [weak self] data in
                Task { await self?.recordReceivedBinary(data) }
            }
        }
    }

    private func handleDataChannelOpen() {
        state = .connected
        let continuation = openContinuation
        openContinuation = nil
        continuation?.resume()
    }

    /// Initialise WebRTC's SSL subsystem exactly once per process.
    /// `RTCInitializeSSL` / `RTCCleanupSSL` are not ref-counted in all SDK
    /// builds; calling cleanup while another connection is live can tear down
    /// SSL globally. A static token avoids both repeated init cost and the
    /// premature-cleanup hazard.
    private static let _webRTCInitOnce: Void = { RTCInitializeSSL() }()
    private static func initializeWebRTC() { _ = _webRTCInitOnce }

    static func defaultConfig() -> RTCConfiguration {
        let config = RTCConfiguration()
        // Empty ICE servers — LAN / Tailscale loopback uses mDNS-derived
        // host candidates only; no STUN/TURN needed in M1.1 scope.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        return config
    }

    private static func setLocalDescription(
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

    private static func setRemoteDescription(
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

    public enum ConnectionError: Error, Equatable, Sendable {
        case peerConnectionInitFailed
        case dataChannelInitFailed
        case sdpGenerationFailed
        case notConfigured
        case notOpen
        case sendFailed
        case closed
    }
}

/// Delegate adapter that bridges WebRTC's NSObject-callback world to
/// Swift closures the surrounding actor sets and reads. WebRTC's SDK
/// dispatches every delegate call for a given peer connection on a
/// fixed internal queue, so the closure properties are read serially —
/// `nonisolated(unsafe)` marks the deliberate sharing across that
/// boundary, while `@Sendable` on the closure type prevents callers
/// from capturing non-Sendable actor state by accident. M1.2 wires
/// signaling onto the ICE candidate signal captured here.
private final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onIceGatheringComplete?()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// `RTCDataChannelDelegate` glue. The actor sets `onOpen` / `onMessage`
/// before awaiting state transitions.
///
/// See `PeerConnectionDelegate` for the rationale on the
/// `nonisolated(unsafe)` + `@Sendable` annotations.
private final class DataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    nonisolated(unsafe) var onMessage: (@Sendable (Data) -> Void)?

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            onOpen?()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}
#endif
