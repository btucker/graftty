#if canImport(WebRTC)
import Foundation
import GrafttyRemoteClient
import GrafttyTunnel
import WebRTC

public enum LoopbackPeerError: Error, Equatable {
    case dataChannelNeverOpened
    case dataChannelOpenTimedOut(label: String)
}

/// An in-process WebRTC peer for loopback tests: plays the far side of a
/// real peer connection (the offerer opposite a host agent, or the answerer
/// opposite `RemoteHostConnection`). Description plumbing and the
/// peer-connection delegate are the production `WebRTCPeerSupport` pieces.
public actor LoopbackPeer: WebRTCIceCandidateReceiver {
    public enum Role: Sendable { case offerer, answerer }

    /// What happens to an inbound data channel when it arrives.
    public enum InboundChannels: Sendable {
        /// Replace the inbox with an open tracker, for callers that await
        /// `openedDataChannel()` and then hand the channel to a transport.
        case trackOpen
        /// Keep the delegate-attached inbox, for callers that take
        /// `arrivedDataChannel(label:)` and replay its buffered bytes.
        case keepInbox
    }

    private let role: Role
    private let inbound: InboundChannels
    /// Created on first negotiation, so a peer that never negotiates starts
    /// no native WebRTC threads.
    private lazy var factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    private var peerConnection: RTCPeerConnection?
    private var dataChannels: [String: RTCDataChannel] = [:]
    /// Inbound channels arrive with the lossless inbox the delegate attached
    /// before WebRTC could deliver a message (see `arrivedDataChannel()`).
    private var inboxes: [String: DataChannelInbox] = [:]
    private nonisolated let pcDelegate = PeerConnectionDelegate()

    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: WebRTCIceCandidateReceiver?

    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var gatheringTimeoutTask: Task<Void, Never>?
    private var openWaits: [String: PendingWait<RTCDataChannel>] = [:]
    private var resolvedOpenDataChannels: [String: RTCDataChannel] = [:]
    private var openTrackers: [String: OpenTrackerDelegate] = [:]
    private var arrivalWaits: [String: PendingWait<(RTCDataChannel, DataChannelInbox)>] = [:]

    private static let gatheringTimeout: Duration = .seconds(5)
    public static let defaultLabel = "graftty-ssh"
    /// Matches `RemoteHostConnection`'s own data-channel open deadline.
    public static let defaultOpenTimeout: Duration = .seconds(30)

    public init(role: Role, inbound: InboundChannels = .trackOpen) {
        self.role = role
        self.inbound = inbound
        pcDelegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        pcDelegate.onDataChannel = { [weak self] _, dc, inbox in
            Task { await self?.adoptInboundDataChannel(dc, inbox: inbox) }
        }
    }

    public func createOffer() async throws -> RTCSessionDescription {
        precondition(role == .offerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 1)
        }
        self.peerConnection = pc
        try createDataChannel(label: Self.defaultLabel)

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 3)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await WebRTCPeerSupport.setLocalDescription(pc, offer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? offer
    }

    public func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        precondition(role == .answerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 4)
        }
        self.peerConnection = pc

        try await WebRTCPeerSupport.setRemoteDescription(pc, offer)
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 5)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await WebRTCPeerSupport.setLocalDescription(pc, answer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? answer
    }

    public func applyAnswer(_ answer: RTCSessionDescription) async throws {
        precondition(role == .offerer)
        guard let pc = peerConnection else { throw NSError(domain: "LoopbackPeer", code: 6) }
        try await WebRTCPeerSupport.setRemoteDescription(pc, answer)
    }

    /// Opens an outbound, ordered data channel with `label`.
    public func createDataChannel(label: String) throws {
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let dc = peerConnection?.dataChannel(forLabel: label, configuration: config) else {
            throw NSError(domain: "LoopbackPeer", code: 2)
        }
        dataChannels[label] = dc
        installOpenTracker(on: dc)
    }

    /// Blocks until the channel with `label` reaches `.open`, then returns
    /// it, or throws `.dataChannelOpenTimedOut` after `timeout`. An inbound
    /// channel is tracked only with `inbound: .trackOpen`.
    public func openedDataChannel(
        label: String = defaultLabel,
        timeout: Duration = defaultOpenTimeout
    ) async throws -> RTCDataChannel {
        if let dc = resolvedOpenDataChannels[label] { return dc }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCDataChannel, Error>) in
            self.openWaits[label] = PendingWait(continuation: continuation, timeout: timeout) { [weak self] in
                await self?.expireOpenWait(label)
            }
        }
    }

    /// Resolves as soon as the answerer's inbound DataChannel OBJECT with
    /// `label` and its lossless inbox exist (`didOpen dataChannel` attached
    /// the inbox synchronously). Callers wrap the pair in
    /// `SSHNIOTransport(dataChannel:inbox:)`; bytes the peer sent in the
    /// meantime replay from the inbox. Opposite `RemoteHostConnection`,
    /// pass `GrafttyWebRTC.dataChannelLabel`. Throws
    /// `.dataChannelOpenTimedOut` if nothing arrives within `timeout`.
    public func arrivedDataChannel(
        label: String = defaultLabel,
        timeout: Duration = defaultOpenTimeout
    ) async throws -> (RTCDataChannel, DataChannelInbox) {
        if let dc = dataChannels[label], let inbox = inboxes[label] { return (dc, inbox) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(RTCDataChannel, DataChannelInbox), Error>) in
            self.arrivalWaits[label] = PendingWait(continuation: continuation, timeout: timeout) { [weak self] in
                await self?.expireArrivalWait(label)
            }
        }
    }

    private func expireOpenWait(_ label: String) {
        openWaits.removeValue(forKey: label)?
            .resume(with: .failure(LoopbackPeerError.dataChannelOpenTimedOut(label: label)))
    }

    private func expireArrivalWait(_ label: String) {
        arrivalWaits.removeValue(forKey: label)?
            .resume(with: .failure(LoopbackPeerError.dataChannelOpenTimedOut(label: label)))
    }

    public func bindIceCandidates(to peer: WebRTCIceCandidateReceiver) {
        self.iceCandidateTarget = peer
        let drained = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        Task {
            for candidate in drained {
                try? await peer.addRemoteIceCandidate(candidate)
            }
        }
    }

    private func routeLocalIceCandidate(_ candidate: RTCIceCandidate) {
        if let target = iceCandidateTarget {
            Task { try? await target.addRemoteIceCandidate(candidate) }
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    public func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func adoptInboundDataChannel(_ dc: RTCDataChannel, inbox: DataChannelInbox) {
        dataChannels[dc.label] = dc
        inboxes[dc.label] = inbox
        arrivalWaits.removeValue(forKey: dc.label)?.resume(with: .success((dc, inbox)))
        if inbound == .trackOpen {
            installOpenTracker(on: dc)
        }
    }

    private func installOpenTracker(on dc: RTCDataChannel) {
        let tracker = OpenTrackerDelegate()
        tracker.onOpen = { [weak self] in
            Task { await self?.handleDataChannelOpen(dc) }
        }
        if dc.readyState == .open {
            Task { self.handleDataChannelOpen(dc) }
        }
        dc.delegate = tracker
        self.openTrackers[dc.label] = tracker
    }

    private func handleDataChannelOpen(_ dc: RTCDataChannel) {
        guard resolvedOpenDataChannels[dc.label] == nil else { return }
        resolvedOpenDataChannels[dc.label] = dc
        openWaits.removeValue(forKey: dc.label)?.resume(with: .success(dc))
        openTrackers[dc.label] = nil
    }

    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = continuation
            pcDelegate.onIceGatheringComplete = { [weak self] _ in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                handleIceGatheringComplete()
                return
            }
            self.gatheringTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gatheringTimeout)
                await self?.handleIceGatheringComplete()
            }
        }
    }

    private func handleIceGatheringComplete() {
        let pending = gatheringContinuation
        gatheringContinuation = nil
        pcDelegate.onIceGatheringComplete = nil
        gatheringTimeoutTask?.cancel()
        gatheringTimeoutTask = nil
        pending?.resume()
    }

    public func close() {
        handleIceGatheringComplete()
        for pending in openWaits.values {
            pending.resume(with: .failure(LoopbackPeerError.dataChannelNeverOpened))
        }
        openWaits.removeAll()
        for pending in arrivalWaits.values {
            pending.resume(with: .failure(LoopbackPeerError.dataChannelNeverOpened))
        }
        arrivalWaits.removeAll()
        for channel in dataChannels.values { channel.close() }
        dataChannels.removeAll()
        inboxes.removeAll()
        peerConnection?.close()
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
    }
}

/// A caller parked in `openedDataChannel` or `arrivedDataChannel`, paired
/// with its deadline. Every resolution (the channel event, the deadline, or
/// `close()`) goes through `resume(with:)`, which also retires the deadline.
private struct PendingWait<Value> {
    private let continuation: CheckedContinuation<Value, Error>
    private let deadline: Task<Void, Never>

    init(
        continuation: CheckedContinuation<Value, Error>,
        timeout: Duration,
        onExpiry: @escaping @Sendable () async -> Void
    ) {
        self.continuation = continuation
        self.deadline = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            await onExpiry()
        }
    }

    func resume(with result: Result<Value, Error>) {
        deadline.cancel()
        continuation.resume(with: result)
    }
}

/// Notifies once a channel reaches `.open`. Whoever wraps the channel next
/// (an SSH transport) installs its own delegate, replacing this one.
private final class OpenTrackerDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open { onOpen?() }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
#endif
