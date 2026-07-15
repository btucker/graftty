#if canImport(UIKit)
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// R2 architecture decision gate. Pairs two `RTCPeerConnection`s
/// in-process, wraps each side's resulting `RTCDataChannel` in an
/// `SSHNIOTransport`, installs `NIOSSHHandler` on each end (client +
/// server), and verifies that an SSH `exec` session round-trips a fixed
/// response.
///
/// Per the SSH-over-WebRTC design doc §11.1, R2 must demonstrate a
/// clean `exec` round-trip before R3 commits to wiring SSH into
/// production code paths. If this test fails or hangs, the entire
/// architectural approach is in question.
///
/// The DataChannel pairing follows the same pattern as the M1.1
/// `RemoteHostConnectionLoopbackTests`: both sides of the connection
/// are stood up as test actors, SDP + ICE candidates are exchanged
/// directly (no signaling endpoint), and once both `RTCDataChannel`s
/// reach `.open` the SSH stack is layered on top. The R2 patch keeps
/// production code untouched — `RemoteHostConnection` and
/// `WebRTCHostAgent` know nothing about SSH yet; that wiring lands in
/// R3+.
@Suite("SSH-over-WebRTC loopback — exec round-trip (R2 gate)")
struct SSHOverWebRTCLoopbackTests {

    /// `.timeLimit(.minutes(3))` guards against the entire test runner
    /// hanging on a CI-only path; locally this test completes in ~10s
    /// (dominated by ICE gathering on the iOS Simulator). If the test
    /// exceeds 3 minutes, Swift Testing kills it and emits a failure with
    /// the stage prints below, so we can diagnose where it hung instead
    /// of staring at a 15-minute job timeout. The 3-minute ceiling is
    /// chased upward across R2/R3 iterations as macos-26 runner-pool
    /// variability has surfaced (10s typical, 40-60s on slow days);
    /// 3 minutes is roughly 10x the worst observed CI time.
    @Test(.timeLimit(.minutes(3)))
    func execRoundTripOverPairedDataChannels() async throws {
        // Diagnostic prints at each stage so a CI hang surfaces with
        // a usable trace in the test log. Cheap on a passing run.
        print("[ssh-loopback] stage=start")

        // 1. Build two paired peer connections in-process.
        let offerer = LoopbackPeer(role: .offerer)
        let answerer = LoopbackPeer(role: .answerer)
        print("[ssh-loopback] stage=peers-built")

        // 2. Offerer creates the offer + its outbound DataChannel.
        let offer = try await offerer.createOffer()
        print("[ssh-loopback] stage=offer-created")

        // 3. Hand the offer to the answerer, which constructs its
        //    peer connection, accepts it, and produces an answer.
        let answer = try await answerer.accept(offer: offer)
        print("[ssh-loopback] stage=answer-built")

        // 4. Wire ICE candidates both directions. Each side has buffered
        //    candidates emitted during the gathering pass; this drains
        //    them in arrival order and forwards future candidates live.
        await offerer.bindIceCandidates(to: answerer)
        await answerer.bindIceCandidates(to: offerer)
        print("[ssh-loopback] stage=ice-bound")

        // 5. Apply the answer on the offerer and wait until both sides
        //    have an open DataChannel.
        try await offerer.applyAnswer(answer)
        print("[ssh-loopback] stage=answer-applied")
        let offererDC = try await offerer.openedDataChannel()
        print("[ssh-loopback] stage=offerer-dc-open")
        let answererDC = try await answerer.openedDataChannel()
        print("[ssh-loopback] stage=answerer-dc-open")

        // 6. Wrap each side's RTCDataChannel in an SSHNIOTransport and
        //    start them. `start()` blocks until the DataChannel is open
        //    (which it already is) and then fires channelActive through
        //    the embedded pipeline so any handlers we add next observe
        //    a live channel.
        let clientTransport = SSHNIOTransport(dataChannel: offererDC)
        let serverTransport = SSHNIOTransport(dataChannel: answererDC)

        // 7. Install the server's NIOSSHHandler BEFORE starting the
        //    transport so channelActive (fired by start()) is the
        //    handler's first event. Same on the client side. Order
        //    matters: NIOSSHHandler.channelActive kicks off the SSH
        //    protocol greeting, and if the handler is added late we'd
        //    miss the initial flush.
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let clientKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())

        // Server side: any pubkey auth accepted, exec request honored
        // by writing the canned response.
        try await serverTransport.eventLoop.submit {
            let serverConfig = SSHServerConfiguration(
                hostKeys: [hostKey],
                userAuthDelegate: AcceptAnyServerUserAuthDelegate()
            )
            let sshHandler = NIOSSHHandler(
                role: .server(serverConfig),
                allocator: serverTransport.channel.allocator,
                inboundChildChannelInitializer: { childChannel, channelType in
                    guard case .session = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(LoopbackExecResponder())
                    }
                }
            )
            try serverTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
        }.get()

        // Client side: any host key accepted (auth lands in R3), single
        // pubkey offered for userauth.
        let responsePromise = clientTransport.eventLoop.makePromise(of: String.self)
        try await clientTransport.eventLoop.submit {
            let clientConfig = SSHClientConfiguration(
                userAuthDelegate: SingleKeyClientUserAuthDelegate(
                    username: "loopback",
                    privateKey: clientKey
                ),
                serverAuthDelegate: AcceptAnyHostKeyDelegate()
            )
            let sshHandler = NIOSSHHandler(
                role: .client(clientConfig),
                allocator: clientTransport.channel.allocator,
                inboundChildChannelInitializer: nil
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(sshHandler)
            // After handshake we'll open a session channel; that work
            // lives in a separate handler so we can react to userauth
            // completion (signaled by channelActive on the child channel).
            let opener = ClientSessionOpener(
                command: "ls",
                completePromise: responsePromise
            )
            try clientTransport.channel.pipeline.syncOperations.addHandler(opener)
        }.get()

        // 8. Now that both pipelines are wired, fire channelActive on
        //    both sides. NIOSSHHandler will write its initial greeting
        //    on channelActive, which `OutboundRelayHandler` ships across
        //    the DataChannel to the peer.
        try await serverTransport.start()
        print("[ssh-loopback] stage=server-started")
        try await clientTransport.start()
        print("[ssh-loopback] stage=client-started")

        // 9. Wait for the round-trip. The timeout is driven by NIO's
        //    own scheduler (failing the promise) rather than a Swift
        //    TaskGroup so that a hung NIOSSHHandler/EventLoopFuture
        //    can't pin the TaskGroup's child tasks forever — that
        //    was the original 15-minute CI hang. Scheduling on the
        //    event loop means the timeout fires reliably even if
        //    cooperative cancellation isn't honored downstream.
        let timeoutTask = clientTransport.eventLoop.scheduleTask(in: .seconds(10)) {
            responsePromise.fail(LoopbackError.timedOut)
        }
        defer { timeoutTask.cancel() }
        let response = try await responsePromise.futureResult.get()
        print("[ssh-loopback] stage=response-received")
        #expect(response == "loopback-exec-ok\n", "Expected exec response from loopback SSH server")

        // 10. Tear down. Close client first so the server sees a clean
        //     EOF rather than a yanked SCTP stream.
        // TODO(R4): shut down NIOAsyncTestingEventLoop instances after
        //     transport close — currently orphaned but lightweight in a
        //     one-test process.
        await clientTransport.close()
        await serverTransport.close()
        await offerer.close()
        await answerer.close()
        print("[ssh-loopback] stage=torn-down")
    }
}

// MARK: - SSH Helpers

private enum LoopbackError: Error {
    case unexpectedChannelType
    case dataChannelNeverOpened
    case timedOut
    case channelInactiveBeforeResponse
}

/// Accepts any publickey userauth request. R3 replaces this with a
/// real delegate that validates against `TrustedPeerStore`.
private final class AcceptAnyServerUserAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .publicKey:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// Accepts any host key. R3 replaces this with `PinnedHostStore`-backed
/// verification.
private final class AcceptAnyHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// Offers a single pubkey on the first attempt, then gives up. This is
/// enough to satisfy `AcceptAnyServerUserAuthDelegate` and prove the
/// userauth round-trip works.
private final class SingleKeyClientUserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var offered = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: privateKey))
        )
        nextChallengePromise.succeed(offer)
    }
}

/// Server-side session-channel handler. Reacts to an inbound `exec`
/// request by writing the canned response and closing the channel.
private final class LoopbackExecResponder: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let execRequest = event as? SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        // If the client asked for a reply, ack the exec request first
        // so the client's pipeline doesn't sit waiting for a success
        // event before reading bytes.
        if execRequest.wantReply {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        }

        let response = "loopback-exec-ok\n"
        var buffer = context.channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))

        let writePromise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(self.wrapOutboundOut(data), promise: writePromise)

        writePromise.futureResult.whenComplete { _ in
            // Send exit-status, then close. NIOSSH translates the close
            // into channel EOF + close on the peer side.
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
                .whenComplete { _ in
                    context.close(promise: nil)
                }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // The exec test doesn't expect inbound stdin; drop quietly.
        _ = self.unwrapInboundIn(data)
    }
}

/// Client-side handler installed on the SSH parent channel. Waits for
/// channelActive (SSH handshake start), then once user-auth completes
/// the SSH handler will be ready to multiplex; we open a session
/// channel, exec the command, and accumulate bytes until EOF.
///
/// We can't sit on `channelActive` directly because that fires before
/// the SSH handshake / userauth completes. Instead, we look for
/// `NIOSSHUserAuthenticationSucceededEvent` (the inbound user event
/// NIOSSH fires when auth completes) and trigger the createChannel
/// from there.
///
/// To keep the test simple and avoid hunting for that exact event
/// type, we enqueue the `createChannel` call immediately at
/// `channelActive`. NIOSSH buffers it in
/// `NIOSSHHandler.pendingChannelInitializations` and processes it on
/// the next `channelReadComplete` after `hasActivated` is true (i.e.
/// after userauth completes). So a single `createChannel` call at
/// `channelActive` is sufficient — no retry is involved.
private final class ClientSessionOpener: ChannelInboundHandler {
    typealias InboundIn = Never

    private let command: String
    private let completePromise: EventLoopPromise<String>

    init(command: String, completePromise: EventLoopPromise<String>) {
        self.command = command
        self.completePromise = completePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try context.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        } catch {
            completePromise.fail(error)
            return
        }
        let promise = context.eventLoop.makePromise(of: Channel.self)
        let command = self.command
        let completePromise = self.completePromise
        sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
            guard case .session = channelType else {
                return childChannel.eventLoop.makeFailedFuture(LoopbackError.unexpectedChannelType)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                let collector = LoopbackExecCollector(
                    command: command,
                    completePromise: completePromise
                )
                try childChannel.pipeline.syncOperations.addHandler(collector)
            }
        }
        promise.futureResult.whenFailure { error in
            completePromise.fail(error)
        }
    }
}

/// Installed on the client's session child channel. On channelActive
/// (= the SSH session has opened) it triggers an exec request, then
/// accumulates inbound channel data into a buffer until the channel
/// closes (server-driven EOF + close).
private final class LoopbackExecCollector: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let completePromise: EventLoopPromise<String>
    private var collected: ByteBuffer?

    init(command: String, completePromise: EventLoopPromise<String>) {
        self.command = command
        self.completePromise = completePromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Allow the remote half-close so EOF doesn't immediately tear
        // the child channel down — we want to read the response bytes
        // before close fires.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest).whenFailure { error in
            self.completePromise.fail(error)
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        guard channelData.type == .channel, case .byteBuffer(var bytes) = channelData.data else {
            return
        }
        if collected == nil {
            collected = bytes
        } else {
            collected?.writeBuffer(&bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let buffer = collected {
            let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
            completePromise.succeed(str)
        } else {
            completePromise.fail(LoopbackError.channelInactiveBeforeResponse)
        }
        context.fireChannelInactive()
    }
}

// MARK: - Loopback peer

/// Test-only actor that wraps a single side (offerer or answerer) of
/// the loopback WebRTC pairing. Mirrors `TestAnswerer` from the M1.1
/// loopback test, but exposes the raw `RTCDataChannel` (rather than
/// going through `RemoteHostConnection.sendBinary` / `lastReceivedBinary`)
/// so we can hand the DataChannel to an `SSHNIOTransport`.
///
/// Kept inline rather than extracted as a shared helper per the R2
/// plan recommendation — the duplication is small and the answerer
/// here behaves slightly differently from `RemoteHostConnection` in
/// that we want raw DataChannel access rather than a managed connection.
private actor LoopbackPeer: WebRTCIceCandidateReceiver {
    enum Role { case offerer, answerer }

    private let role: Role
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private nonisolated let pcDelegate = LoopbackPeerConnectionDelegate()

    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: WebRTCIceCandidateReceiver?

    /// Continuation resumed when ICE gathering completes (or the 5s
    /// simulator-fallback timeout fires).
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var gatheringTimeoutTask: Task<Void, Never>?
    /// Continuation resumed when the DataChannel reaches `.open`. Used
    /// by both roles to publish the open DataChannel to the test body.
    private var openContinuation: CheckedContinuation<RTCDataChannel, Error>?
    private var resolvedOpenDataChannel: RTCDataChannel?

    private static let gatheringTimeout: Duration = .seconds(5)

    init(role: Role) {
        self.role = role
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)

        // Buffer local candidates emitted before bindIceCandidates is called.
        pcDelegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        // Offerer creates the DataChannel itself; the answerer receives
        // the DataChannel through this callback.
        pcDelegate.onDataChannel = { [weak self] dc in
            Task { await self?.adoptInboundDataChannel(dc) }
        }
    }

    func createOffer() async throws -> RTCSessionDescription {
        precondition(role == .offerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 1)
        }
        self.peerConnection = pc

        // Create our outbound DataChannel; attach the open-tracking delegate
        // so once it transitions to `.open` we can resume any waiters.
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: "graftty-ssh", configuration: dcConfig) else {
            throw NSError(domain: "LoopbackPeer", code: 2)
        }
        self.dataChannel = dc
        installOpenTracker(on: dc)

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 3)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, offer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? offer
    }

    func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        precondition(role == .answerer)
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: pcDelegate) else {
            throw NSError(domain: "LoopbackPeer", code: 4)
        }
        self.peerConnection = pc

        try await Self.setRemoteDescription(pc, offer)
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "LoopbackPeer", code: 5)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, answer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? answer
    }

    func applyAnswer(_ answer: RTCSessionDescription) async throws {
        precondition(role == .offerer)
        guard let pc = peerConnection else { throw NSError(domain: "LoopbackPeer", code: 6) }
        try await Self.setRemoteDescription(pc, answer)
    }

    /// Block until our DataChannel reaches `.open`, then return it.
    /// Works for both roles: the offerer's open tracker is installed
    /// in `createOffer`; the answerer's in `adoptInboundDataChannel`.
    func openedDataChannel() async throws -> RTCDataChannel {
        if let dc = resolvedOpenDataChannel { return dc }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCDataChannel, Error>) in
            self.openContinuation = continuation
        }
    }

    func bindIceCandidates(to peer: WebRTCIceCandidateReceiver) {
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

    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func adoptInboundDataChannel(_ dc: RTCDataChannel) {
        // Answerer side: SDP negotiation hands us the peer's DataChannel.
        self.dataChannel = dc
        installOpenTracker(on: dc)
    }

    /// Wraps the supplied DataChannel's delegate with a stateChanged hook
    /// that resolves `openContinuation` (or stores the channel for a later
    /// `openedDataChannel()` call) the moment it reaches `.open`.
    ///
    /// We use a dedicated delegate object per DataChannel; `RTCDataChannel.delegate`
    /// is `weak`, so we stash it on the actor as `currentOpenTracker` to keep
    /// it alive. The tracker only handles the open-transition signal — the SSH
    /// transport's own delegate (installed by `SSHNIOTransport.init`) takes
    /// over once we hand the DataChannel to it. That works because
    /// `RTCDataChannel.delegate` can be reassigned without re-running the
    /// "did open" callback, and the open transition has already occurred by
    /// the time we hand off. Additionally, `handleDataChannelOpen`'s Task
    /// body holds no reference to the tracker itself — it only reads actor
    /// state — so the mid-flight delegate swap is safe even if the Task
    /// hasn't yet executed when the swap happens.
    private nonisolated(unsafe) var currentOpenTracker: OpenTrackerDelegate?

    private func installOpenTracker(on dc: RTCDataChannel) {
        let tracker = OpenTrackerDelegate()
        tracker.onOpen = { [weak self] in
            Task { await self?.handleDataChannelOpen(dc) }
        }
        // If by some race the channel is already `.open` (unlikely on
        // freshly-constructed objects, but cheap to check) resolve
        // immediately.
        if dc.readyState == .open {
            Task { self.handleDataChannelOpen(dc) }
        }
        dc.delegate = tracker
        self.currentOpenTracker = tracker
    }

    private func handleDataChannelOpen(_ dc: RTCDataChannel) {
        guard resolvedOpenDataChannel == nil else { return }
        resolvedOpenDataChannel = dc
        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume(returning: dc)
        }
        // Once resolved, drop the tracker — the SSHNIOTransport will
        // install its own delegate when the test wraps the DataChannel.
        currentOpenTracker = nil
    }

    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = continuation
            pcDelegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                handleIceGatheringComplete()
                return
            }
            // iOS simulator falls back; see RemoteHostConnection.
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

    func close() {
        if let pending = gatheringContinuation {
            gatheringContinuation = nil
            pcDelegate.onIceGatheringComplete = nil
            gatheringTimeoutTask?.cancel()
            gatheringTimeoutTask = nil
            pending.resume()
        }
        if let pending = openContinuation {
            openContinuation = nil
            pending.resume(throwing: LoopbackError.dataChannelNeverOpened)
        }
        dataChannel?.close()
        peerConnection?.close()
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
    }

    private static func setLocalDescription(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func setRemoteDescription(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

// MARK: - WebRTC delegate shims

private final class LoopbackPeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    nonisolated(unsafe) var onDataChannel: (@Sendable (RTCDataChannel) -> Void)?
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { onIceGatheringComplete?() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

/// Tiny RTCDataChannelDelegate that just notifies when the channel
/// reaches `.open`. The SSHNIOTransport installs its own delegate
/// (replacing this one) once we've handed off the DataChannel.
private final class OpenTrackerDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open { onOpen?() }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
#endif
