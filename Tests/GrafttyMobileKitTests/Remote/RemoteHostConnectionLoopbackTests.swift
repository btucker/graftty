#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// Loopback test: construct a `RemoteHostConnection` (offerer, mobile-side)
/// and a paired in-process answerer using the bundled WebRTC SDK, exchange
/// SDP + ICE in-process (no signaling endpoint yet), verify a DataChannel
/// opens, and verify a byte ping-pong round-trips.
///
/// This is the M1.1 acceptance criterion: SDK integration works, peer
/// connection negotiates, data channel opens. M1.2 replaces the in-process
/// SDP swap with an HTTPS signaling endpoint; M1.3 adds Noise before any
/// channel traffic; M1.4 framing.
@Suite("WebRTC SDK integration — loopback DataChannel ping-pong (M1.1 foundation).")
struct RemoteHostConnectionLoopbackTests {

    @Test(.disabled("""
        RemoteHostConnection now installs an SSH handshake after the \
        DataChannel opens (R4). TestAnswerer does not speak SSH, so \
        applyAnswer() would hang until the 30-second timeout fires and \
        then throw. DataChannel connectivity is still verified by \
        SSHAuthLoopbackTests (R3) which adds an SSH server on the \
        answerer side.
        """))
    func twoConnectionsExchangeBytesOverDataChannel() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        )
        let client = RemoteHostConnection(
            clientKey: clientKey,
            expectedHostFingerprint: hostFingerprint
        )
        let answererPeer = TestAnswerer()

        // 1. Client creates offer.
        let offer = try await client.createOffer()

        // 2. In a real flow this would be POSTed to /v1/rtc/offer.
        //    Here we feed it straight into the answerer.
        let answer = try await answererPeer.accept(offer: offer)

        // 3. Forward ICE candidates each way. Both sides buffer candidates
        //    emitted during the initial gathering pass (which happens
        //    inside `createOffer` / `accept` before this point), then
        //    drain in arrival order when their target is bound.
        await client.bindIceCandidates(to: answererPeer)
        await answererPeer.bindIceCandidates(to: client)

        // 4. Apply the answer on the client; this waits for the data
        //    channel to reach the `open` state on the offerer side.
        try await client.applyAnswer(answer)

        // 5. Send a binary ping from the client; the answerer should
        //    receive it within a short window.
        let ping = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try await client.sendBinary(ping)

        try await pollUntil(timeout: .seconds(5)) {
            await answererPeer.lastReceived == ping
        }

        // 6. Send a binary pong back; the client should receive it.
        let pong = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await answererPeer.send(pong)

        try await pollUntil(timeout: .seconds(5)) {
            await client.lastReceivedBinary == pong
        }

        await client.close()
        await answererPeer.close()
    }

    // MARK: - Task 1 (W3): terminal-state observability
    //
    // These reuse the M1.1 `TestAnswerer` (raw WebRTC, no SSH) rather
    // than a full SSH-speaking peer. That's sufficient here because
    // `RemoteHostConnection.installSSHHandlerAndResume`'s success path
    // (the one that sets `.connected`) only waits for the LOCAL
    // DataChannel to reach `.open` and the local SSH handler to be
    // installed — it does not wait for the remote peer to complete a
    // real SSH handshake. `TestAnswerer` not speaking SSH is exactly
    // why `twoConnectionsExchangeBytesOverDataChannel` above is
    // disabled (its raw ping/pong assertions relied on
    // `RemoteHostConnection`'s own `dataChannelDelegate.onMessage`,
    // which `SSHNIOTransport` now steals by re-assigning
    // `dataChannel.delegate`) — but that breakage is orthogonal to
    // `.connected` firing, which these tests confirm still happens.

    /// @spec-less regression test (Task 1 has no @spec ID — see the task
    /// brief): a normal offer/answer/ICE negotiation must fire the
    /// observer with `.connected` once the DataChannel opens and the SSH
    /// handler installs successfully.
    @Test(.timeLimit(.minutes(1)))
    func connectedTransitionFiresDuringNormalNegotiation() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        )
        let client = RemoteHostConnection(
            clientKey: clientKey,
            expectedHostFingerprint: hostFingerprint
        )
        let recorder = StateChangeRecorder()
        // Set BEFORE createOffer — see `RemoteHostConnection.onStateChange`'s
        // doc comment for the race this ordering avoids.
        await client.setOnStateChange { recorder.record($0) }
        let answererPeer = TestAnswerer()

        let offer = try await client.createOffer()
        let answer = try await answererPeer.accept(offer: offer)
        await client.bindIceCandidates(to: answererPeer)
        await answererPeer.bindIceCandidates(to: client)
        try await client.applyAnswer(answer)

        #expect(
            recorder.recorded.contains(.connected),
            "expected a .connected transition, observed \(recorder.recorded)"
        )

        await client.close()
        await answererPeer.close()
    }

    /// The mirror of the host-side first-bytes race: the HOST writes its
    /// SSH version banner the instant the host's open notification lands,
    /// which can precede this client's own open notification handling by
    /// several scheduler hops. If the client only constructs its
    /// inbound-buffering transport at its open notification, the host
    /// banner lands on a delegate that discards it and the handshake
    /// stalls forever. Arming the transport at channel creation closes
    /// the window: from that point every inbound byte is buffered.
    @Test("""
@spec REMOTE-11.3: When the client creates its data channel, the connection shall install the inbound-buffering SSH transport immediately, before the channel opens, so bytes the host writes upon its own open notification are never dropped.
""", .timeLimit(.minutes(1)))
    func transportIsArmedAtChannelCreationBeforeOpen() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        )
        let client = RemoteHostConnection(
            clientKey: clientKey,
            expectedHostFingerprint: hostFingerprint
        )
        _ = try await client.createOffer()

        #expect(await client.sshTransportForTesting != nil)

        await client.close()
    }

    /// The CI-flake mechanism behind IPAD-5.2's intermittent 15s pollUntil
    /// timeout: signaling can trickle the answerer's candidates to the
    /// offerer BEFORE the answer SDP is applied. libwebrtc rejects
    /// `add(_:)` until a remote description exists, and every caller in
    /// the trickle path swallows the error — so on machines where the 5s
    /// gathering timeout ships candidate-poor SDPs, the dropped batch
    /// leaves ICE unable to connect. Early candidates must buffer, then
    /// drain once the answer is applied.
    @Test("""
@spec REMOTE-11.2: If a remote ICE candidate arrives before the answer has been applied, then the connection shall buffer it and add it to the peer connection once the remote description is set, rather than dropping it.
""", .timeLimit(.minutes(1)))
    func remoteCandidateArrivingBeforeAnswerIsBufferedThenDrained() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        )
        let client = RemoteHostConnection(
            clientKey: clientKey,
            expectedHostFingerprint: hostFingerprint
        )
        let offer = try await client.createOffer()

        // A syntactically valid host candidate delivered before any
        // answer exists — today this is rejected by libwebrtc and the
        // rejection is swallowed by the trickle path's callers.
        let early = RTCIceCandidate(
            sdp: "candidate:842163049 1 udp 1677729535 127.0.0.1 54555 typ host generation 0",
            sdpMLineIndex: 0,
            sdpMid: "0"
        )
        try await client.addRemoteIceCandidate(early)
        #expect(await client.pendingRemoteCandidateCountForTesting == 1)

        // Applying the answer drains the buffer (the bogus candidate just
        // fails its connectivity checks; real candidates arrive inside
        // the answer SDP) and the negotiation still completes.
        let answerer = TestAnswerer()
        let answer = try await answerer.accept(offer: offer)
        await client.bindIceCandidates(to: answerer)
        await answerer.bindIceCandidates(to: client)
        try await client.applyAnswer(answer)
        #expect(await client.pendingRemoteCandidateCountForTesting == 0)

        await client.close()
        await answerer.close()
    }

    /// Killing the answerer out from under an established connection must
    /// land the client on exactly one terminal transition — never zero,
    /// never two. Both an ICE `.failed` report and the DataChannel
    /// closing (RTCDataChannelState `.closing`/`.closed`) can plausibly
    /// fire for this one underlying event; `RemoteHostConnection`'s
    /// `setState` must gate on whichever lands first.
    @Test(.timeLimit(.minutes(1)))
    func killingAnswererFiresExactlyOneTerminalTransition() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        )
        let client = RemoteHostConnection(
            clientKey: clientKey,
            expectedHostFingerprint: hostFingerprint
        )
        let recorder = StateChangeRecorder()
        await client.setOnStateChange { recorder.record($0) }
        let answererPeer = TestAnswerer()

        let offer = try await client.createOffer()
        let answer = try await answererPeer.accept(offer: offer)
        await client.bindIceCandidates(to: answererPeer)
        await answererPeer.bindIceCandidates(to: client)
        try await client.applyAnswer(answer)

        // Kill both the answerer's DataChannel and its RTCPeerConnection.
        // The client observes this as its own DataChannel closing
        // (SCTP-level teardown, fast) and/or its ICE connection failing
        // (potentially much slower) — either is a valid terminal trigger;
        // the assertion below is that only one ever lands.
        await answererPeer.close()

        try await pollUntil(timeout: .seconds(15)) {
            recorder.recorded.contains { $0.isTerminal }
        }

        let terminalTransitions = recorder.recorded.filter { $0.isTerminal }
        #expect(
            terminalTransitions.count == 1,
            "expected exactly one terminal transition, observed \(recorder.recorded)"
        )

        await client.close()
    }

    /// `close()` must be idempotent: the second call is a no-op, so the
    /// observer only ever sees one `.closed`.
    @Test(.timeLimit(.minutes(1)))
    func explicitCloseFiresClosedExactlyOnce() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        )
        let client = RemoteHostConnection(
            clientKey: clientKey,
            expectedHostFingerprint: hostFingerprint
        )
        let recorder = StateChangeRecorder()
        await client.setOnStateChange { recorder.record($0) }
        let answererPeer = TestAnswerer()

        let offer = try await client.createOffer()
        let answer = try await answererPeer.accept(offer: offer)
        await client.bindIceCandidates(to: answererPeer)
        await answererPeer.bindIceCandidates(to: client)
        try await client.applyAnswer(answer)

        await client.close()
        await client.close()

        let closedTransitions = recorder.recorded.filter { $0 == .closed }
        #expect(
            closedTransitions.count == 1,
            "expected close() to fire .closed exactly once, observed \(recorder.recorded)"
        )

        await answererPeer.close()
    }
}

/// Records every `RemoteHostConnection.State` the observer fires, in
/// order. `onStateChange` is a plain `@Sendable` closure invoked
/// synchronously from actor-isolated code, so an NSLock-guarded class
/// (matching the pattern used by other loopback test collectors, e.g.
/// `PromiseCompleter` in `SSHAuthLoopbackTests.swift`) lets the test
/// body read it back without its own actor hop.
private final class StateChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [RemoteHostConnection.State] = []

    func record(_ state: RemoteHostConnection.State) {
        lock.lock(); defer { lock.unlock() }
        states.append(state)
    }

    var recorded: [RemoteHostConnection.State] {
        lock.lock(); defer { lock.unlock() }
        return states
    }
}

/// Test helper that owns the answerer side of the loopback. Production
/// uses `WebRTCHostAgent` from GrafttyKit, but that target isn't
/// importable here; we duplicate the minimal answerer logic inline so
/// the loopback proves the mobile-side `RemoteHostConnection` works in
/// isolation. The Mac-side test in `GrafttyKitTests` will mirror.
private actor TestAnswerer: WebRTCIceCandidateReceiver {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    /// `nonisolated let` so the `onDataChannel` callback (which fires on
    /// WebRTC's serial queue) can install `dc.delegate` and the
    /// `onMessage` closure **synchronously**, before any message has a
    /// chance to race in. The previous design queued a `Task { await
    /// adopt }`; if the first message arrived during the actor-queue gap
    /// between Task dispatch and Task execution, `dc.delegate` was nil
    /// and WebRTC dropped the message. The delegate classes are
    /// `@unchecked Sendable`.
    private nonisolated let delegate = AnswererDelegate()
    private nonisolated let dataChannelDelegate = AnswererDataChannelDelegate()
    private(set) var lastReceived: Data?
    /// Mirror of `RemoteHostConnection.pendingLocalCandidates` — buffer
    /// candidates gathered during `accept` until the test binds a target,
    /// so the offerer doesn't starve waiting for our host candidates.
    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: RemoteHostConnection?

    init() {
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        // See `RemoteHostConnection.init` — install the candidate sink
        // up-front so candidates emitted during `accept`'s ICE gathering
        // pass (before `bindIceCandidates` is called) are buffered.
        delegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        // Install dc routing synchronously so the first inbound message
        // is never dropped to a nil delegate during an actor-queue gap.
        // Stashing the dc reference (for `send`) can still go through
        // the actor since `send` is only driven by the test after
        // `applyAnswer` returns.
        delegate.onDataChannel = { [weak self] dc in
            guard let self else { return }
            dc.delegate = self.dataChannelDelegate
            self.dataChannelDelegate.onMessage = { [weak self] data in
                Task { await self?.record(data) }
            }
            Task { await self.captureDataChannel(dc) }
        }
    }

    private func captureDataChannel(_ dc: RTCDataChannel) {
        self.dataChannel = dc
    }

    private func routeLocalIceCandidate(_ candidate: RTCIceCandidate) async {
        if let target = iceCandidateTarget {
            try? await target.addRemoteIceCandidate(candidate)
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw NSError(domain: "TestAnswerer", code: 1)
        }
        self.peerConnection = pc

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "TestAnswerer", code: 2)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // Wait for ICE gathering to complete so the answer SDP includes
        // every `a=candidate:` line — mirrors WebRTCHostAgent.acceptOffer.
        // Without this, the client's connection has no remote candidates
        // and the data channel never opens, hanging the test forever.
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? answer
    }

    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = continuation
            delegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                handleIceGatheringComplete()
                return
            }
            // iOS simulator's WebRTC can't see real interfaces and stays
            // in `.gathering` forever otherwise.
            self.gatheringTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gatheringTimeout)
                await self?.handleIceGatheringComplete()
            }
        }
    }

    private static let gatheringTimeout: Duration = .seconds(5)
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var gatheringTimeoutTask: Task<Void, Never>?

    private func handleIceGatheringComplete() {
        let pending = gatheringContinuation
        gatheringContinuation = nil
        delegate.onIceGatheringComplete = nil
        gatheringTimeoutTask?.cancel()
        gatheringTimeoutTask = nil
        pending?.resume()
    }

    func send(_ data: Data) async throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw NSError(domain: "TestAnswerer", code: 3)
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else {
            throw NSError(domain: "TestAnswerer", code: 4)
        }
    }

    func bindIceCandidates(to client: RemoteHostConnection) {
        self.iceCandidateTarget = client
        let drained = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        // Single Task, sequential awaits — mirror of
        // `RemoteHostConnection.bindIceCandidates`. Per-candidate Tasks
        // would race on the receiver's executor.
        Task {
            for candidate in drained {
                try? await client.addRemoteIceCandidate(candidate)
            }
        }
    }

    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() {
        if let pending = gatheringContinuation {
            gatheringContinuation = nil
            delegate.onIceGatheringComplete = nil
            gatheringTimeoutTask?.cancel()
            gatheringTimeoutTask = nil
            pending.resume()
        }
        dataChannel?.close()
        peerConnection?.close()
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
    }

    fileprivate func record(_ data: Data) {
        self.lastReceived = data
    }
}

private final class AnswererDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    nonisolated(unsafe) var onDataChannel: (@Sendable (RTCDataChannel) -> Void)?
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
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

private final class AnswererDataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onMessage: (@Sendable (Data) -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}

/// Poll until `condition()` returns true or the deadline expires. Used
/// instead of arbitrary `Task.sleep` so the test exits promptly on
/// success but still fails clearly when the condition genuinely doesn't
/// hold. Throws on timeout so the test stops at the first failure point
/// rather than cascading into follow-up failures triggered by the same
/// root cause.
private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(50),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
#endif
