import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOSSH
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

    private let hostKey: Curve25519.Signing.PrivateKey
    private let trustedPeerStore: TrustedPeerStore
    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private var panesStateSubscribe: PanesStateChannelHandler.Subscribe
    private var paneControlMutator: PaneControlChannelHandler.Mutator
    /// REMOTE-9: the SAME process-wide store the `/ws` bridge uses
    /// (`AppServices.displayOwnershipStore`), so a Mac-side or web-side
    /// owner change reaches SSH terminal clients and vice versa. This
    /// agent constructs its own `DisplayOwnershipBroadcaster` wrapping
    /// that store rather than sharing the web side's broadcaster
    /// instance — `DisplayOwnershipBroadcaster.init(store:)` subscribes
    /// to every store mutation regardless of which broadcaster (or which
    /// transport's coordinator) caused it, so two broadcaster instances
    /// fanning out from the same store already gives full cross-transport
    /// propagation without sharing the instance itself.
    private let displayOwnershipStore: SessionDisplayOwnershipStore
    private let displayOwnershipBroadcaster: DisplayOwnershipBroadcaster
    private var sshTransport: SSHNIOTransport?
    private var sshInstallStarted = false

    /// REMOTE-3.1 revocation (W4): the process-wide map from authenticated
    /// peer to this connection's close action. Registered once userauth
    /// resolves the peer's `RemoteDeviceID` (see `onAuthenticated` below)
    /// and deregistered in `close()` so a revoked-then-reconnected peer's
    /// next `revoke` hits the CURRENT connection rather than a stale
    /// closure over a torn-down agent.
    private let sshConnectionRegistry: SSHConnectionRegistry
    /// Set once userauth succeeds on this connection's SSH transport and
    /// this connection's entry is registered. `close()` reads this to
    /// deregister the right key — AND generation — from
    /// `sshConnectionRegistry`; nil until `registerAuthenticatedConnection`
    /// completes, which happens at most once per `installSSHHandler` call
    /// (one connection, one peer).
    ///
    /// Carrying the `RegistrationToken` alongside the device ID (rather
    /// than deregistering by device ID alone) is what makes `close()`'s
    /// fire-and-forget deregister Task identity-scoped: if this connection
    /// was already replaced by a reconnect (`register` closed this one and
    /// installed a new token for the same device), this stale token no
    /// longer matches what's stored, so `deregister` becomes a no-op
    /// instead of wiping the newer connection's live entry.
    private var authenticatedRegistration: (deviceID: RemoteDeviceID, token: SSHConnectionRegistry.RegistrationToken)?

    /// Built lazily, on first `acceptOffer` use, rather than in `init` — an
    /// agent that never negotiates never touches native libwebrtc. This is
    /// what keeps mac CI's REMOTE-11.1 busy-guard test (which never
    /// negotiates) free of native WebRTC work; see `SignalingHandlerOutcomeTests`
    /// for the CI hang this was extracted to fix. Production behavior is
    /// unchanged: the factory still exists before any real negotiation.
    private lazy var factory: RTCPeerConnectionFactory = {
        // SSL and codec subsystems are process-wide; initialize once,
        // immediately before the first native factory build.
        Self.initializeWebRTC()
        // nil factories: DataChannel-only — no video codec work needed.
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }()
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

    public init(
        hostKey: Curve25519.Signing.PrivateKey,
        trustedPeerStore: TrustedPeerStore,
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        panesStateSubscribe: @escaping PanesStateChannelHandler.Subscribe,
        paneControlMutator: @escaping PaneControlChannelHandler.Mutator,
        displayOwnershipStore: SessionDisplayOwnershipStore,
        sshConnectionRegistry: SSHConnectionRegistry = SSHConnectionRegistry()
    ) {
        self.hostKey = hostKey
        self.trustedPeerStore = trustedPeerStore
        self.streamFactory = streamFactory
        self.panesStateSubscribe = panesStateSubscribe
        self.paneControlMutator = paneControlMutator
        self.displayOwnershipStore = displayOwnershipStore
        self.displayOwnershipBroadcaster = DisplayOwnershipBroadcaster(store: displayOwnershipStore)
        self.sshConnectionRegistry = sshConnectionRegistry
        self.delegate = PeerConnectionDelegate()
        self.dataChannelDelegate = DataChannelDelegate()
    }

    /// Replace the `panes-state` subscription callback. The R5 wiring path
    /// constructs the host agent in `GrafttyApp.init()` (before SwiftUI
    /// `@State` is accessible) with a stub, then swaps in the production
    /// closure from `startup()`. Safe to call multiple times — the snapshotted
    /// value is re-read on every `installSSHHandler` call. Must be invoked
    /// before the signaling handler is wired so no data channel can open
    /// with the stub still in place.
    public func setPanesStateSubscribe(_ subscribe: @escaping PanesStateChannelHandler.Subscribe) {
        self.panesStateSubscribe = subscribe
    }

    /// Replace the `pane-control` mutator callback. See `setPanesStateSubscribe`
    /// for the timing contract — both setters share the same init/startup
    /// split and the same "wire before signaling" ordering requirement.
    public func setPaneControlMutator(_ mutator: @escaping PaneControlChannelHandler.Mutator) {
        self.paneControlMutator = mutator
    }

    /// Test-only seam mirroring `acceptOffer`'s busy-guard precondition
    /// surface (`state == .idle || state == .closed`), so a test can put
    /// the agent into `.answering` / `.connected` and exercise the guard
    /// without driving any native WebRTC negotiation to get there — see
    /// `SignalingHandlerOutcomeTests.busyOfferDoesNotTearDownActiveConnection`.
    /// `internal` so `@testable import GrafttyHostAgent` can reach it.
    internal func setStateForTesting(_ newState: State) {
        state = newState
    }

    /// Accept an incoming offer and return the answer.
    public func acceptOffer(_ offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        // Reject concurrent / re-entered offers — two parallel offers
        // would otherwise clobber `peerConnection`, `dataChannel`, and
        // the delegate's onDataChannel closure.
        guard state == .idle || state == .closed else {
            throw HostError.busy
        }
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
        if let transport = sshTransport {
            Task { await transport.close() }
            sshTransport = nil
        }
        if let (deviceID, token) = authenticatedRegistration {
            // Remove the stale entry so a later `revoke` of this same
            // peer (after it reconnects) hits the NEW connection's
            // closure rather than this torn-down one. `deregister` is
            // a no-op if `revoke` already removed the entry, OR if a
            // reconnect already replaced it with a fresh token (that's
            // the identity-scoping `token` provides — see
            // `authenticatedRegistration`'s doc comment).
            authenticatedRegistration = nil
            let registry = sshConnectionRegistry
            Task { await registry.deregister(deviceID: deviceID, token: token) }
        }
        state = .closed
        if let pc = peerConnection {
            pc.close()
            peerConnection = nil
        }
        dataChannel?.close()
        dataChannel = nil
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
            Task { await self?.installSSHHandler() }
        }
        dataChannelDelegate.onMessage = { [weak self] data in
            Task { await self?.recordReceivedBinary(data) }
        }
        if dc.readyState == .open {
            Task { await installSSHHandler() }
        }
    }

    private func recordReceivedBinary(_ data: Data) {
        lastReceivedBinary = data
    }

    private func installSSHHandler() async {
        guard !sshInstallStarted else { return }
        sshInstallStarted = true
        guard let dc = dataChannel else { return }
        let transport = SSHNIOTransport(dataChannel: dc)
        self.sshTransport = transport  // assign before start so close() can find it
        let factory = streamFactory
        let panesStateSubscribe = self.panesStateSubscribe
        let paneControlMutator = self.paneControlMutator
        let ownershipStore = self.displayOwnershipStore
        let ownershipBroadcaster = self.displayOwnershipBroadcaster
        // REMOTE-9.1: NIOSSH authenticates the connection before any
        // channel can open, so `onAuthenticated` (called synchronously
        // inside `SSHUserAuthDelegate.requestReceived`, before the
        // success outcome is returned) always populates this box before
        // `inboundChildChannelInitializer` runs for the first channel.
        let peerBox = AuthenticatedPeerBox()
        do {
            try await transport.eventLoop.submit { [hostKey, trustedPeerStore] in
                let handler = SSHServerSetup.makeHandler(
                    hostKey: hostKey,
                    trustedPeerStore: trustedPeerStore,
                    allocator: transport.channel.allocator,
                    onAuthenticated: { [weak self] deviceID in
                        peerBox.deviceID = deviceID
                        // REMOTE-3.1 revocation (W4): `onAuthenticated` runs
                        // synchronously on the transport's event loop, not
                        // on this actor, and `SSHConnectionRegistry.register`
                        // is async — so registration happens via a Task
                        // hop rather than inline here. That means a
                        // channel-open racing this Task's actor hop is
                        // possible in theory, but harmless: `peerBox`
                        // (read by every child channel's `deviceIDProvider`)
                        // is already populated synchronously above, and
                        // the registry's only job is to make a FUTURE
                        // `revoke` able to find this connection — it
                        // doesn't gate channel-open.
                        Task { await self?.registerAuthenticatedConnection(deviceID: deviceID) }
                    },
                    inboundChildChannelInitializer: { child, channelType in
                        guard case .session = channelType else {
                            return child.eventLoop.makeFailedFuture(WebRTCHostAgentError.unsupportedChannelType)
                        }
                        return child.eventLoop.makeCompletedFuture {
                            let dispatcher = SubsystemDispatcher(
                                streamFactory: factory,
                                panesStateSubscribe: panesStateSubscribe,
                                paneControlMutator: paneControlMutator,
                                ownershipStore: ownershipStore,
                                ownershipBroadcaster: ownershipBroadcaster,
                                deviceIDProvider: { peerBox.deviceID }
                            )
                            try child.pipeline.syncOperations.addHandler(dispatcher)
                        }
                    }
                )
                try transport.channel.pipeline.syncOperations.addHandler(handler)
            }.get()
            try await transport.start()
            // Preserve `.closed` if `close()` ran during the await above —
            // otherwise we'd flip state back to `.connected` after the
            // transport has been torn down, claiming a working connection
            // when the underlying transport is gone.
            if self.state != .closed {
                self.state = .connected
            }
        } catch {
            await transport.close()
            self.sshTransport = nil
            if self.state != .closed {
                self.state = .failed(reason: "SSH install failed: \(error)")
            }
        }
    }

    /// REMOTE-3.1 revocation (W4): records this connection's close action
    /// under the authenticated peer's `RemoteDeviceID` so a later admin
    /// action (`SSHConnectionRegistry.revoke`) can close it. Invoked
    /// from a `Task` spawned inside `SSHUserAuthDelegate.onAuthenticated`
    /// (see the call site's comment for why this can't happen inline).
    ///
    /// Guards against registering a connection that's already torn
    /// down: if `close()` ran before this Task's actor hop completed
    /// (state flips to `.closed` synchronously as one of `close()`'s
    /// first steps), skip registering — otherwise `close`'s own
    /// closure would run and immediately re-close an already-closed
    /// agent, and the registry would hold a dangling entry until the
    /// peer reconnects.
    private func registerAuthenticatedConnection(deviceID: RemoteDeviceID) async {
        guard state != .closed else { return }
        // NOTE on the residual window this guard doesn't close (finding 2,
        // W4 review): `close()` is synchronous and non-reentrant on this
        // actor, so it can only interleave here while the `await` below is
        // suspended. If it does, `close()` finds `authenticatedRegistration`
        // still nil (this method hasn't set it yet) and so has nothing to
        // deregister; when this method resumes it still installs the entry,
        // now for an already-`.closed` agent. That leaves one phantom
        // registry entry — `count` overcounts by one — until the SAME peer
        // either reconnects (`register`'s replace-path awaits and no-ops
        // this dead closure, then installs the real one) or is revoked
        // (`revoke` removes it and no-ops the dead closure). Both are
        // existing, already-tested paths, so this is treated as an
        // acceptable, self-correcting window rather than adding a second
        // post-await state check purely to close it.
        authenticatedRegistration = (
            deviceID,
            await sshConnectionRegistry.register(deviceID: deviceID) { [weak self] in
                await self?.close()
            }
        )
    }

    private enum WebRTCHostAgentError: Error {
        case unsupportedChannelType
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
        /// `acceptOffer` was called while a prior offer was still in flight
        /// or the agent was already connected. Only one peer connection at
        /// a time — the second offer is rejected rather than clobbering
        /// the live one.
        case busy
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

/// Thread-safe box holding the `RemoteDeviceID` of the peer that
/// completed SSH userauth on this connection. One instance per
/// `installSSHHandler` call (i.e. per data channel / SSH connection);
/// `SSHUserAuthDelegate.onAuthenticated` sets `deviceID` synchronously
/// during userauth, and `SubsystemDispatcher`'s `deviceIDProvider`
/// reads it once per child channel thereafter.
private final class AuthenticatedPeerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _deviceID: RemoteDeviceID?

    var deviceID: RemoteDeviceID? {
        get { lock.lock(); defer { lock.unlock() }; return _deviceID }
        set { lock.lock(); defer { lock.unlock() }; _deviceID = newValue }
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
