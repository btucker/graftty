#if canImport(UIKit)
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

        /// `true` for the two terminal values. `RemoteHostConnection.setState`
        /// refuses any further transition once this is true — see its doc
        /// comment. `internal` (the type's default access level, not
        /// `private`) rather than re-derived elsewhere: the loopback test's
        /// own terminal-transition assertions read this directly via
        /// `@testable import` instead of duplicating the switch, which
        /// would risk silently drifting out of sync with this one if a
        /// case is ever added.
        var isTerminal: Bool {
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
    private nonisolated let dataChannelDelegate: DataChannelDelegate

    /// Continuation that resumes when the data channel transitions to
    /// `open`. Set during `connect`, resumed by `dataChannelDidChangeState`.
    private var openContinuation: CheckedContinuation<Void, Error>?

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
        self.dataChannelDelegate = DataChannelDelegate()
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
        // The data channel can die (peer closed it, transport reset)
        // without ICE ever reporting `.failed` — this is the other
        // terminal signal. Installed on the shared delegate object
        // up-front; it stays wired across whichever concrete
        // `RTCDataChannel` `createOffer`/`applyAnswer` later attaches
        // it to.
        self.dataChannelDelegate.onClosed = { [weak self] in
            Task { await self?.handleDataChannelClosed() }
        }
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
        dc.delegate = dataChannelDelegate
        self.dataChannel = dc
        // Install the message handler at channel-creation time, NOT
        // inside `waitForDataChannelOpen`. The previous design only set
        // `onMessage` inside the open-wait continuation, so the
        // already-open early-return path (channel reached `.open`
        // between `applyAnswer`'s `setRemoteDescription` and the first
        // state-check) left `onMessage` nil and silently dropped every
        // inbound frame. The loopback test exposed this as the *second*
        // pollUntil (pong receipt) timing out after 5s — the first
        // pollUntil (ping receipt on answerer) and an instrumented CI
        // failure trace narrowed it down.
        dataChannelDelegate.onMessage = { [weak self] data in
            Task { await self?.recordReceivedBinary(data) }
        }

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
            try await waitForDataChannelOpen()
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
        onClosed: @escaping @Sendable (String) async -> Void
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
            // Detach `onClose` first: `setState` already guards against a
            // second terminal transition, but without this every teardown
            // that reached SSH install would still pay for a pointless
            // extra `Task { await handleDataChannelClosed() }` hop back
            // into this (already terminal) actor once `transport.close()`
            // fires its own `onClose`.
            transport.onClose = nil
            Task { await transport.close() }
            sshTransport = nil
            sshHandlerBox = nil
        }
        if let pending = iceGatheringContinuation {
            iceGatheringContinuation = nil
            delegate.onIceGatheringComplete = nil
            pending.resume()
        }
        if let pending = openContinuation {
            openContinuation = nil
            pending.resume(throwing: ConnectionError.closed)
        }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
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

    private func waitForDataChannelOpen() async throws {
        if dataChannel?.readyState == .open {
            // DataChannel was already open before we got here; install SSH
            // directly (no continuation needed — we're already on the actor).
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.openContinuation = continuation
                Task { await self.installSSHHandlerAndResume() }
            }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.openContinuation = continuation
            self.dataChannelDelegate.onOpen = { [weak self] in
                Task { await self?.installSSHHandlerAndResume() }
            }
            // `onMessage` is installed up-front in `createOffer`, so we
            // do NOT re-install it here. The previous design installed
            // it here and skipped it on the early-return path above —
            // see the createOffer comment for the bug that caused.
            // No redundant re-check here: the early-return path at the
            // top of waitForDataChannelOpen handles the already-open case,
            // and installSSHHandlerAndResume is guarded by sshInstallStarted.
            self.openTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.dataChannelOpenTimeout)
                await self?.handleDataChannelOpenTimeout()
            }
        }
    }

    private func installSSHHandlerAndResume() async {
        guard !sshInstallStarted else { return }
        sshInstallStarted = true
        guard let dc = dataChannel else { return }
        // Passed to the initializer (not assigned after construction) so
        // there is no window between `SSHNIOTransport.init` re-assigning
        // `dc.delegate` to its own internal delegate — which is what
        // stops `dataChannelDelegate.onClosed` (wired in `RemoteHostConnection.init`)
        // from observing this DataChannel any further — and this closure
        // being wired up to replace it as the way to learn the
        // DataChannel died.
        let transport = SSHNIOTransport(dataChannel: dc) { [weak self] in
            Task { await self?.handleDataChannelClosed() }
        }
        self.sshTransport = transport  // assign before start so close() can find it
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
            self.sshHandlerBox = box
            openTimeoutTask?.cancel()
            openTimeoutTask = nil
            // If openContinuation is nil, the open already timed out or
            // close() resumed it; don't overwrite .failed/.closed with .connected.
            if let cont = openContinuation {
                openContinuation = nil
                setState(.connected)
                cont.resume(returning: ())
            }
        } catch {
            await transport.close()
            self.sshTransport = nil
            if let cont = openContinuation {
                openContinuation = nil
                setState(.failed(reason: "SSH handshake failed: \(error)"))
                cont.resume(throwing: error)
            }
        }
    }

    private func handleDataChannelOpenTimeout() {
        guard let continuation = openContinuation else { return }
        openContinuation = nil
        openTimeoutTask = nil
        // Detach the `.open` callback so a late state transition cannot
        // re-enter `handleDataChannelOpen` after we've failed the
        // connection. Mirrors `handleIceGatheringComplete`'s cleanup.
        dataChannelDelegate.onOpen = nil
        setState(.failed(reason: "data channel did not open within \(Self.dataChannelOpenTimeout)"))
        continuation.resume(throwing: ConnectionError.dataChannelOpenTimedOut)
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

/// `RTCDataChannelDelegate` glue. The actor sets `onOpen` / `onMessage`
/// before awaiting state transitions.
///
/// See `PeerConnectionDelegate` for the rationale on the
/// `nonisolated(unsafe)` + `@Sendable` annotations.
private final class DataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    nonisolated(unsafe) var onMessage: (@Sendable (Data) -> Void)?
    /// Fires on `.closing` or `.closed` — see
    /// `RemoteHostConnection.handleDataChannelClosed`.
    nonisolated(unsafe) var onClosed: (@Sendable () -> Void)?

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            onOpen?()
        case .closing, .closed:
            onClosed?()
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}
#endif
