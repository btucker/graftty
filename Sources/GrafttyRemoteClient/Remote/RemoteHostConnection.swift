import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOSSH
import WebRTC

/// Common interface for "thing that can accept ICE candidates from a
/// peer." Used by the loopback test to wire ICE both directions
/// without a signaling endpoint. Real signaling (M1.2) replaces this.
public protocol WebRTCIceCandidateReceiver: Sendable {
    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws
}

/// Client-side actor that owns a single `RTCPeerConnection` to a paired
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

        /// `true` for the two terminal values. `RemoteHostConnection.setState`
        /// refuses any further transition once this is true — see its doc
        /// comment. Public because connection lifecycle coordinators live in
        /// platform UI modules while this state machine is shared by macOS
        /// and iOS. Keeping the predicate here avoids duplicating the
        /// terminal-case switch across consumers if a state is added later.
        public var isTerminal: Bool {
            switch self {
            case .failed, .closed: return true
            case .idle, .connecting, .connected: return false
            }
        }
    }

    public private(set) var state: State = .idle

    /// Fires on every transition into `.connected`, `.failed`, or
    /// `.closed` — the three states Task 2's coordinator (eviction) and
    /// Task 4's reconnect logic need to observe. Set via
    /// `setOnStateChange(_:)` (an async actor call) BEFORE
    /// `createOffer()` so no transition can slip by before a caller
    /// wires up its observer — there is no synchronous/nonisolated
    /// setter, which would otherwise leave a window between
    /// construction and observer registration.
    private var onStateChange: (@Sendable (State) -> Void)?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    /// `nonisolated let` so `init` can hand the delegate to
    /// `RTCPeerConnectionFactory.peerConnection(with:...)` without
    /// crossing the actor boundary, and the delegate's closures can be
    /// invoked from WebRTC's internal queue without an extra hop.
    /// The delegate classes are `@unchecked Sendable`; their mutable
    /// closure properties carry `nonisolated(unsafe) @Sendable` and
    /// are themselves the explicit synchronization contract with
    /// WebRTC's internal dispatch queue.
    private nonisolated let delegate: PeerConnectionDelegate

    /// Continuation resumed when `iceGatheringState` first reaches `.complete`.
    /// Stored on the actor so the delegate's callback can hop back into
    /// actor-isolated context for a safe single-resume.
    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?
    private var iceGatheringTimeoutTask: Task<Void, Never>?

    /// Locally-gathered ICE candidates emitted before a forwarding target
    /// is bound. Drained in arrival order when `bindIceCandidates(to:)`
    /// runs. Without this buffer, candidates emitted between
    /// `setLocalDescription` and the caller wiring up a target are
    /// delivered to a nil sink and lost — which (with no STUN/TURN and
    /// only host candidates) starves the remote peer of any way to reach
    /// us, leaving the data channel stuck unconfigured. M1.2 signaling
    /// will sit between gathering and "target available" the same way,
    /// so the buffer belongs in production, not just the test path.
    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: WebRTCIceCandidateReceiver?

    /// Remote ICE candidates that arrived before `applyAnswer` set the
    /// remote description. libwebrtc rejects `add(_:)` until a remote
    /// description exists, so trickled candidates that race ahead of the
    /// answer must be held and added once `applyAnswer` succeeds — the
    /// receive-side mirror of `pendingLocalCandidates` above. Without
    /// this buffer the race is invisible when ICE gathering completes
    /// fast (candidates ride inside the SDPs), but on a loaded machine
    /// the 5s gathering timeout ships candidate-poor SDPs and the
    /// dropped trickle batch leaves ICE unable to connect.
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var remoteDescriptionApplied = false

    /// Test seam: how many early remote candidates are currently buffered.
    internal var pendingRemoteCandidateCountForTesting: Int {
        pendingRemoteCandidates.count
    }

    /// Bound on how long `waitForIceGatheringComplete` will block when the
    /// SDK never emits `.complete` (iOS simulator, locked-down networks).
    /// Real LAN gathering completes in <100ms, so this only fires in
    /// degenerate environments.
    private static let iceGatheringTimeout: Duration = .seconds(5)

    /// Most-recently received binary frame. Test-only entry point —
    /// production code routes through the channel-framing layer
    /// added in a later PR. `internal` so the in-target test can read it
    /// via `@testable import`.
    internal private(set) var lastReceivedBinary: Data?

    private let clientKey: Curve25519.Signing.PrivateKey
    private let expectedHostFingerprint: RemoteIdentityFingerprint
    private var sshTransport: SSHNIOTransport?

    /// Test seam: whether the inbound-buffering transport is armed.
    /// REMOTE-11.3 pins that this is non-nil from channel creation.
    internal var sshTransportForTesting: SSHNIOTransport? { sshTransport }
    private var sshInstallStarted = false
    /// `NIOSSHHandler` is not declared `Sendable`; wrap in an
    /// `@unchecked Sendable` box so the actor can hold it as a stored
    /// property. All accesses go through actor-isolated methods, so
    /// the lack of internal Sendable enforcement is safe here.
    private var sshHandlerBox: SSHHandlerBox?

    public init(
        clientKey: Curve25519.Signing.PrivateKey,
        expectedHostFingerprint: RemoteIdentityFingerprint
    ) {
        // SSL and codec subsystems are process-wide; initialize once.
        Self.initializeWebRTC()
        // nil factories: DataChannel-only — no video codec work needed.
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        self.delegate = PeerConnectionDelegate()
        self.clientKey = clientKey
        self.expectedHostFingerprint = expectedHostFingerprint

        // Install the candidate sink up-front so candidates emitted
        // before `bindIceCandidates(to:)` is called (i.e. during the
        // first ICE gathering pass) are captured rather than dropped.
        // The actor hop preserves arrival order even when the delegate
        // fires on WebRTC's internal queue.
        self.delegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        // ICE-failed is a terminal signal — see `handleIceStateChange`
        // for why `.disconnected` is deliberately NOT treated the same
        // way. Installed up-front (like `onIceCandidate` above) so a
        // failure that lands before `createOffer` completes is still
        // observed.
        self.delegate.onIceStateChange = { [weak self] iceState in
            Task { await self?.handleIceStateChange(iceState) }
        }
        // The data-channel-death terminal signal is wired via the
        // closed-callback passed to `SSHNIOTransport.init` in
        // `performCreateOffer` — the transport owns the channel delegate
        // from creation onward (REMOTE-11.3).
    }

    /// Registers the observer fired on every transition into
    /// `.connected`, `.failed`, or `.closed`. An async actor call (not a
    /// plain settable property) so callers reliably sequence it before
    /// `createOffer()` — see the `onStateChange` doc comment for the
    /// race this avoids.
    public func setOnStateChange(_ handler: (@Sendable (State) -> Void)?) {
        onStateChange = handler
    }

    /// Build the local peer connection and create the data channel.
    /// Returns the local SDP offer for signaling-side hand-off.
    ///
    /// Wraps `performCreateOffer` so ANY failure along the way (peer
    /// connection / data channel init, SDP generation, `setLocalDescription`)
    /// routes through `setState(.failed(reason:))` before rethrowing —
    /// without this, a setup-time failure would leave `state` stuck at
    /// `.idle`/`.connecting` forever with no `onStateChange` firing and
    /// the half-built `RTCPeerConnection` never torn down, silently
    /// violating the "fires on every terminal transition" contract this
    /// task adds.
    public func createOffer() async throws -> RTCSessionDescription {
        do {
            return try await performCreateOffer()
        } catch {
            setState(.failed(reason: "offer creation failed: \(error)"))
            throw error
        }
    }

    private func performCreateOffer() async throws -> RTCSessionDescription {
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
            forLabel: GrafttyWebRTC.dataChannelLabel,
            configuration: dataChannelConfig
        ) else {
            throw ConnectionError.dataChannelInitFailed
        }
        self.dataChannel = dc
        // Arm the inbound-buffering SSH transport IMMEDIATELY at channel
        // creation — before the channel can possibly open (REMOTE-11.3).
        // `SSHNIOTransport.init` takes over the channel delegate and
        // buffers every inbound byte; `start()` (in
        // `startSSHOverDataChannel`) parks until the channel opens. The
        // host writes its SSH version banner the instant the HOST's open
        // notification lands, which can precede this client's own open
        // handling by several scheduler hops — constructing the transport
        // at our open notification (the previous shape) let that banner
        // land on a delegate that discarded it, and the handshake stalled
        // forever with both sides waiting. The closed-callback passed to
        // the initializer is how this actor learns the DataChannel died,
        // from creation onward.
        let transport = SSHNIOTransport(dataChannel: dc) { [weak self] in
            Task { await self?.handleDataChannelClosed() }
        }
        self.sshTransport = transport

        setState(.connecting)

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

    /// See `WebRTCHostAgent.waitForIceGatheringComplete` (in the `GrafttyHostAgent` target) for the rationale.
    /// A 5-second timeout falls through with whatever candidates were gathered.
    /// On the iOS simulator, gathering can stay in `.gathering` indefinitely
    /// when the SDK can't see real network interfaces — the timeout keeps the
    /// offer flow making progress instead of hanging.
    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.iceGatheringContinuation = continuation
            self.delegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            // Re-check inside the actor: if gathering completed between
            // the early-return check and installing the callback, resume
            // immediately. Idempotent — `handleIceGatheringComplete` does
            // nothing when the continuation is already nil.
            if pc.iceGatheringState == .complete {
                self.handleIceGatheringComplete()
                return
            }
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

    /// Apply the answer received from the remote host and return when
    /// the data channel is open (or throw on failure / timeout).
    ///
    /// Failures already routed through `setState(.failed(reason:))`
    /// deeper in `waitForDataChannelOpen` (handshake failure, open
    /// timeout) hit the `isTerminal` guard here and no-op, so this outer
    /// catch only actually fires the observer for a failure that happens
    /// BEFORE that point — `setRemoteDescription` throwing, or this being
    /// called with no peer connection configured.
    public func applyAnswer(_ answer: RTCSessionDescription) async throws {
        do {
            guard let pc = peerConnection else { throw ConnectionError.notConfigured }
            try await Self.setRemoteDescription(pc, answer)
            remoteDescriptionApplied = true
            // Drain candidates that trickled in ahead of the answer.
            // Best-effort per candidate, mirroring the trickle path's
            // semantics — one malformed candidate must not fail the
            // whole answer application. (REMOTE-11.2)
            let drained = pendingRemoteCandidates
            pendingRemoteCandidates.removeAll()
            for candidate in drained {
                try? await Self.addCandidate(candidate, to: pc)
            }
            try await startSSHOverDataChannel()
        } catch {
            setState(.failed(reason: "apply answer failed: \(error)"))
            throw error
        }
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
    /// remote peer's connection. Candidates emitted before this call
    /// are buffered (see `pendingLocalCandidates`) and forwarded in
    /// arrival order; later candidates are forwarded directly. The
    /// M1.1 loopback test wires this directly to the answerer; M1.2
    /// will plug in the signaling endpoint as the `peer` instead.
    public func bindIceCandidates(to peer: WebRTCIceCandidateReceiver) {
        self.iceCandidateTarget = peer
        let drained = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        // Single Task with sequential awaits so the receiving peer
        // sees candidates in arrival order. Per-candidate Tasks would
        // race against each other on the peer's executor.
        Task {
            for candidate in drained {
                try? await peer.addRemoteIceCandidate(candidate)
            }
        }
    }

    private func routeLocalIceCandidate(_ candidate: RTCIceCandidate) async {
        if let target = iceCandidateTarget {
            try? await target.addRemoteIceCandidate(candidate)
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    /// Apply an ICE candidate received from the remote peer. Candidates
    /// arriving before `applyAnswer` has set the remote description are
    /// buffered (libwebrtc rejects them with "remote description was
    /// null") and added once the answer is applied. (REMOTE-11.2)
    public func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { throw ConnectionError.notConfigured }
        guard remoteDescriptionApplied else {
            pendingRemoteCandidates.append(candidate)
            return
        }
        try await Self.addCandidate(candidate, to: pc)
    }

    private static func addCandidate(_ candidate: RTCIceCandidate, to pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }

    /// Open a new SSH terminal session over the established connection.
    /// Throws `ConnectionError.notConnected` if the SSH handshake has not
    /// completed yet (i.e. `applyAnswer` has not returned successfully).
    public func openTerminalSession(sessionName: String) async throws -> TerminalSessionClient {
        guard
            let transport = sshTransport,
            let box = sshHandlerBox
        else {
            throw ConnectionError.notConnected
        }
        let client = TerminalSessionClient(
            parentChannel: transport.channel,
            parentHandler: box.handler,
            sessionName: sessionName
        )
        try await client.connect()
        return client
    }

    /// Opens a `panes-state@graftty.dev` SSH subsystem channel. The
    /// supplied callbacks fire each time the server pushes a snapshot or
    /// the channel closes. Throws `ConnectionError.notConnected` if the
    /// SSH handshake has not completed.
    public func openPanesStateChannel(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void
    ) async throws -> PanesStateChannelClient {
        let client = try makePanesStateClient(
            onSnapshot: onSnapshot,
            onClosed: onClosed
        )
        try await client.open()
        return client
    }

    /// Constructs a `PanesStateChannelClient` against the current SSH
    /// transport but does NOT call `open()` on it. Used by
    /// `buildPaneEnvironment`, where the channel client is wrapped in a
    /// `WorktreePanesStore` and the store's `subscribe()` performs the
    /// single open. Throws `ConnectionError.notConnected` if the SSH
    /// handshake has not completed.
    public func makePanesStateClient(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void,
        originAware: Bool = false,
        requestReply: Bool = false
    ) throws -> PanesStateChannelClient {
        guard
            let transport = sshTransport,
            let box = sshHandlerBox
        else {
            throw ConnectionError.notConnected
        }
        return PanesStateChannelClient(
            parentChannel: transport.channel,
            parentHandler: box.handler,
            subsystemName: originAware
                ? SSHChannelTypeNames.panesStateV2
                : SSHChannelTypeNames.panesState,
            requestReply: requestReply,
            onSnapshot: onSnapshot,
            onClosed: onClosed
        )
    }

    /// Opens the `pane-control@graftty.dev` SSH subsystem channel. Returns
    /// a client ready for typed RPCs (`split`, `close`, `swap`). Throws
    /// `ConnectionError.notConnected` if the SSH handshake has not
    /// completed.
    public func openPaneControlChannel() async throws -> PaneControlChannelClient {
        let client = try makePaneControlClient()
        try await client.open()
        return client
    }

    /// Constructs a `PaneControlChannelClient` against the current SSH
    /// transport but does NOT call `open()` on it. Used by
    /// `buildPaneEnvironment`, where the channel client is wrapped in a
    /// `PaneControlClient` and `PaneControlClient.open()` performs the
    /// single open. Throws `ConnectionError.notConnected` if the SSH
    /// handshake has not completed.
    public func makePaneControlClient() throws -> PaneControlChannelClient {
        guard
            let transport = sshTransport,
            let box = sshHandlerBox
        else {
            throw ConnectionError.notConnected
        }
        return PaneControlChannelClient(
            parentChannel: transport.channel,
            parentHandler: box.handler
        )
    }

    public func openWorktreeManagementChannel() async throws
        -> WorktreeManagementChannelClient {
        let client = try makeWorktreeManagementClient()
        try await client.open()
        return client
    }

    public func makeWorktreeManagementClient() throws
        -> WorktreeManagementChannelClient {
        guard
            let transport = sshTransport,
            let box = sshHandlerBox
        else {
            throw ConnectionError.notConnected
        }
        return WorktreeManagementChannelClient(
            parentChannel: transport.channel,
            parentHandler: box.handler
        )
    }

    public func close() {
        setState(.closed)
    }

    /// Routes every `state` mutation through one place so `onStateChange`
    /// fires exactly once per notify-worthy transition. `.idle` /
    /// `.connecting` update `state` silently — nothing downstream needs
    /// those. `.connected` / `.failed` / `.closed` notify; the latter two
    /// also tear down every live resource first, and — critically — are
    /// refused entirely once `state` is already terminal. That refusal is
    /// what keeps an ICE `.failed` and a DataChannel close (which can
    /// both fire for the same dead peer connection, in either order) from
    /// double-notifying the observer, and what makes `close()` idempotent.
    private func setState(_ newState: State) {
        guard !isTerminal else { return }
        state = newState
        switch newState {
        case .idle, .connecting:
            break
        case .connected:
            onStateChange?(newState)
        case .failed, .closed:
            performTeardown()
            onStateChange?(newState)
        }
    }

    /// `true` once `state` has reached a terminal value. See `setState`.
    private var isTerminal: Bool { state.isTerminal }

    /// Tears down every live resource: the SSH transport, any in-flight
    /// continuations, timeout tasks, and the WebRTC peer/data channel.
    /// Called exactly once, from `setState`, on the first `.failed` or
    /// `.closed` transition.
    private func performTeardown() {
        if let transport = sshTransport {
            Task { await transport.close() }
            sshTransport = nil
            sshHandlerBox = nil
        }
        if let pending = iceGatheringContinuation {
            iceGatheringContinuation = nil
            delegate.onIceGatheringComplete = nil
            pending.resume()
        }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
        pendingRemoteCandidates.removeAll()
        remoteDescriptionApplied = false
    }

    /// `RTCIceConnectionState.failed` means ICE has exhausted every
    /// candidate pair and given up — the connection cannot recover on
    /// its own, so this is terminal.
    ///
    /// `.disconnected` is deliberately NOT terminal: WebRTC enters it on
    /// routine, often-transient network blips (a dropped packet burst, a
    /// brief Wi-Fi/cellular handoff) and frequently recovers back to
    /// `.connected` without any application intervention. Treating it as
    /// terminal would evict/reconnect far more eagerly than the
    /// connection quality actually warrants. A bounded grace timer that
    /// escalates a stuck `.disconnected` to terminal is deferred rather
    /// than added here: no consumer needs it yet (Task 2's coordinator
    /// only needs eviction-on-terminal; Task 4's reconnect owns its own
    /// retry timing), and a timer here would need its own
    /// cancel-on-recovery bookkeeping that's easy to get racy against a
    /// later `.connected`/`.failed` report. Revisit if Task 4 needs
    /// bounded disconnected-time semantics.
    private func handleIceStateChange(_ iceState: RTCIceConnectionState) {
        switch iceState {
        case .failed:
            setState(.failed(reason: "ICE connection failed"))
        default:
            break
        }
    }

    /// The data channel can close (peer hung up, transport reset)
    /// without ICE ever reporting `.failed` first — this is the other
    /// terminal signal `setState`'s dedup guard exists for.
    private func handleDataChannelClosed() {
        setState(.failed(reason: "data channel closed"))
    }

    /// Bound on how long the data channel may stay in `.connecting` after
    /// `applyAnswer` runs. Without this, a stalled negotiation (e.g. ICE
    /// agrees no usable path on the iOS simulator) hangs the test/caller
    /// for the entire 15-min GitHub Actions job timeout — the exact mode
    /// PR #184 hit before this timeout was added.
    private static let dataChannelOpenTimeout: Duration = .seconds(30)
    private var openTimeoutTask: Task<Void, Never>?
    private var didTimeOutOpeningDataChannel = false

    /// Install the client SSH handler on the pre-armed transport and
    /// drive the handshake. The transport was constructed at channel
    /// creation (REMOTE-11.3), so every inbound byte since then is
    /// buffered; `transport.start()` parks until the channel opens (a
    /// channel that dies first makes it throw). The open-timeout task is
    /// the liveness bound: a channel that never opens (ICE stalled with
    /// no usable path) transitions the connection to `.failed`, whose
    /// teardown closes the transport and unparks `start()` with an error.
    private func startSSHOverDataChannel() async throws {
        guard !sshInstallStarted else { return }
        sshInstallStarted = true
        guard let transport = sshTransport else { throw ConnectionError.notConfigured }
        didTimeOutOpeningDataChannel = false
        openTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.dataChannelOpenTimeout)
            } catch {
                return
            }
            await self?.handleDataChannelOpenTimeout()
        }
        do {
            // Wrap the handler in an SSHHandlerBox inside the event-loop
            // submit closure so only the `@unchecked Sendable` box
            // crosses the async boundary, not the bare `NIOSSHHandler`.
            let box: SSHHandlerBox = try await transport.eventLoop.submit { [clientKey, expectedHostFingerprint] in
                let h = SSHClientSetup.makeHandler(
                    clientKey: clientKey,
                    expectedHostFingerprint: expectedHostFingerprint,
                    allocator: transport.channel.allocator
                )
                try transport.channel.pipeline.syncOperations.addHandler(h)
                return SSHHandlerBox(h)
            }.get()
            try await transport.start()
            openTimeoutTask?.cancel()
            openTimeoutTask = nil
            // `setState` refuses transitions once terminal, so a `close()`
            // that ran during the awaits above cannot be overwritten with
            // `.connected` — but don't hand out the handler box either.
            guard !isTerminal else { return }
            self.sshHandlerBox = box
            setState(.connected)
        } catch {
            let surfacedError: Error = didTimeOutOpeningDataChannel
                ? ConnectionError.dataChannelOpenTimedOut
                : error
            openTimeoutTask?.cancel()
            openTimeoutTask = nil
            await transport.close()
            self.sshTransport = nil
            setState(.failed(reason: "SSH handshake failed: \(surfacedError)"))
            throw surfacedError
        }
    }

    private func handleDataChannelOpenTimeout() {
        // Only meaningful while the connection is still coming up — a
        // fired timer racing a successful `.connected` (or an earlier
        // terminal transition) must be a no-op. Failing the state tears
        // the transport down, which unparks `startSSHOverDataChannel`'s
        // waiting `transport.start()` with an error.
        guard state != .connected, !isTerminal else { return }
        openTimeoutTask = nil
        didTimeOutOpeningDataChannel = true
        setState(.failed(reason: "data channel did not open within \(Self.dataChannelOpenTimeout)"))
    }

    /// Initialise WebRTC's SSL subsystem exactly once per process.
    /// `RTCInitializeSSL` / `RTCCleanupSSL` are not ref-counted in all SDK
    /// builds; calling cleanup while another connection is live can tear down
    /// SSL globally. A static token avoids both repeated init cost and the
    /// premature-cleanup hazard.
    private static let _webRTCInitOnce: Void = { RTCInitializeSSL() }()
    private static func initializeWebRTC() { _ = _webRTCInitOnce }

    /// The baseline peer-connection configuration used by Graftty.
    ///
    /// Public so platform adapters and interoperability tests can create the
    /// answering peer with the same LAN-focused ICE policy as this client.
    public static func defaultConfig() -> RTCConfiguration {
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
        case notConnected
        case notOpen
        case sendFailed
        case closed
        case dataChannelOpenTimedOut
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
    /// See `RemoteHostConnection.handleIceStateChange` for which ICE
    /// states are treated as terminal.
    nonisolated(unsafe) var onIceStateChange: (@Sendable (RTCIceConnectionState) -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onIceStateChange?(newState)
    }
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

/// Sendable-compatible container for `NIOSSHHandler`.
///
/// `NIOSSHHandler` is not declared `Sendable` by swift-nio-ssh, but it is
/// safe to transfer across actor boundaries when every call site accesses it
/// exclusively through the event-loop it was created on — which is the case
/// here: `installSSHHandlerAndResume` hands the handler off to
/// `TerminalSessionClient`, which always dispatches via `parentChannel.eventLoop`.
/// The `@unchecked` annotation satisfies the Swift compiler's actor-isolation
/// check while relying on the caller's event-loop discipline for actual safety.
private final class SSHHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler
    init(_ handler: NIOSSHHandler) { self.handler = handler }
}
