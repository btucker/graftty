import Foundation
import GrafttyProtocol
import WebRTC

/// Mac-side actor that accepts incoming WebRTC offers, completes the
/// answer side of the handshake, and exposes the data channel.
///
/// Mirror of `RemoteHostConnection` on the mobile side. Together, the
/// loopback test in `RemoteHostConnectionLoopbackTests` constructs both
/// in-process and verifies the SDK integration works end-to-end before
/// any later PR adds signaling, Noise, or channel framing.
public actor WebRTCHostAgent {

    public enum State: Sendable, Equatable {
        case idle
        case answering
        case connected
        case failed(reason: String)
        case closed
    }

    public private(set) var state: State = .idle

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private let delegate: PeerConnectionDelegate
    private let dataChannelDelegate: DataChannelDelegate

    /// Resumed once `iceGatheringState` first reaches `.complete`. Stored on
    /// the actor so the WebRTC-thread delegate callback and the actor's
    /// re-check can converge through a single actor-isolated handler — the
    /// two paths can't race into a double-resume.
    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?
    private var iceGatheringTimeoutTask: Task<Void, Never>?

    /// See `RemoteHostConnection.iceGatheringTimeout`.
    private static let iceGatheringTimeout: Duration = .seconds(5)

    /// Most-recently received binary frame. Test-only entry point —
    /// production replaces this with channel-framing dispatch in M1.4.
    /// `internal` so the in-target test can read it via `@testable import`.
    internal private(set) var lastReceivedBinary: Data?

    public init() {
        // SSL and codec subsystems are process-wide; initialize once.
        Self.initializeWebRTC()
        // nil factories: DataChannel-only — no video codec work needed.
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        self.delegate = PeerConnectionDelegate()
        self.dataChannelDelegate = DataChannelDelegate()
    }

    /// Accept an incoming offer and return the answer.
    public func acceptOffer(_ offer: RTCSessionDescription) async throws -> RTCSessionDescription {
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
            throw HostError.peerConnectionInitFailed
        }
        self.peerConnection = pc

        // The mobile side is the data-channel creator; the host receives
        // the data channel via `didOpen dataChannel` (handled in
        // `PeerConnectionDelegate.onDataChannel`).
        delegate.onDataChannel = { [weak self] dc in
            Task { await self?.adoptDataChannel(dc) }
        }

        state = .answering
        try await Self.setRemoteDescription(pc, offer)

        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: HostError.sdpGenerationFailed); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, answer)
        await waitForIceGatheringComplete(pc)
        // After gathering completes, `pc.localDescription` has the full
        // SDP with `a=candidate:` lines included.
        return pc.localDescription ?? answer
    }

    /// Block until the peer connection's ICE gathering reaches `.complete`.
    /// Required for non-trickle ICE: only after gathering completes does the
    /// local SDP include every `a=candidate:` line the remote peer needs.
    /// Returns immediately if gathering is already complete.
    ///
    /// The continuation is stored on the actor and resumed via an
    /// actor-isolated handler so the WebRTC-thread delegate callback and
    /// the actor's re-check can't race into a double-resume.
    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.iceGatheringContinuation = continuation
            self.delegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                self.handleIceGatheringComplete()
                return
            }
            // Timeout falls through with whatever candidates were
            // gathered. iOS simulator can stay in `.gathering` indefinitely
            // when the SDK can't see real network interfaces; without this,
            // the answer flow hangs forever.
            self.iceGatheringTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.iceGatheringTimeout)
                await self?.handleIceGatheringComplete()
            }
        }
    }

    private func handleIceGatheringComplete() {
        let pending = iceGatheringContinuation
        iceGatheringContinuation = nil
        delegate.onIceGatheringComplete = nil
        iceGatheringTimeoutTask?.cancel()
        iceGatheringTimeoutTask = nil
        pending?.resume()
    }

    /// Send a binary frame back to the client. Test-only entry point.
    public func sendBinary(_ data: Data) async throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw HostError.notOpen
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else {
            throw HostError.sendFailed
        }
    }

    public func close() {
        if let pending = iceGatheringContinuation {
            iceGatheringContinuation = nil
            delegate.onIceGatheringComplete = nil
            pending.resume()
        }
        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        state = .closed
    }

    private func adoptDataChannel(_ dc: RTCDataChannel) {
        guard dc.label == GrafttyWebRTC.dataChannelLabel else {
            // Unexpected label — close defensively. With Noise handshake (M1.3),
            // peer identity will be authenticated separately; this is belt-and-
            // suspenders.
            dc.close()
            return
        }
        self.dataChannel = dc
        dc.delegate = dataChannelDelegate
        dataChannelDelegate.onOpen = { [weak self] in
            Task { await self?.handleDataChannelOpen() }
        }
        dataChannelDelegate.onMessage = { [weak self] data in
            Task { await self?.recordReceivedBinary(data) }
        }
        if dc.readyState == .open {
            state = .connected
        }
    }

    private func handleDataChannelOpen() {
        state = .connected
    }

    private func recordReceivedBinary(_ data: Data) {
        lastReceivedBinary = data
    }

    /// `RTCInitializeSSL` is process-wide and not refcounted in every SDK
    /// build, so a per-instance `deinit { RTCCleanupSSL() }` would tear SSL
    /// down for other live connections. A one-shot static token initialises
    /// once and never cleans up; this matches what production iOS apps
    /// using WebRTC.framework typically do.
    private static let _webRTCInitOnce: Void = { RTCInitializeSSL() }()
    private static func initializeWebRTC() { _ = _webRTCInitOnce }

    static func defaultConfig() -> RTCConfiguration {
        let config = RTCConfiguration()
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

    public enum HostError: Error, Equatable, Sendable {
        case peerConnectionInitFailed
        case sdpGenerationFailed
        case notOpen
        case sendFailed
    }
}

/// See the matching comment in `RemoteHostConnection.swift` —
/// WebRTC dispatches delegate calls serially per connection, so the
/// unsafe is bounded; `@Sendable` keeps callers honest.
private final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    nonisolated(unsafe) var onDataChannel: (@Sendable (RTCDataChannel) -> Void)?

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
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

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
